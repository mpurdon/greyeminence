import AVFoundation
import CoreAudio

/// Captures system audio using Core Audio Taps (macOS 14.2+).
///
/// Architecture:
/// 1. Create CATapDescription for all system audio output
/// 2. Create an AudioHardwareTap from the description (with a known UUID)
/// 3. Get the default output device UID
/// 4. Create an aggregate device linking the tap (via UUID) and output device
/// 5. Point AVAudioEngine at the aggregate device
/// 6. Install a tap on the engine's input node to get audio buffers
///
/// Requires NSAudioCaptureUsageDescription in Info.plist.
/// The system will prompt the user for permission on first recording attempt.
actor SystemAudioCaptureService {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var audioEngine: AVAudioEngine?
    private var isCapturing = false
    private var continuation: AsyncStream<TaggedAudioBuffer>.Continuation?

    let bufferSize: AVAudioFrameCount = 4096

    /// Start capturing all system audio output.
    func startCapture() throws -> AsyncStream<TaggedAudioBuffer> {
        guard !isCapturing else {
            throw SystemAudioCaptureError.alreadyCapturing
        }

        // Step 1: Create a tap description for all system audio (stereo)
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        let tapUUID = UUID()
        tapDescription.uuid = tapUUID
        tapDescription.name = "GreyEminence System Audio Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        // Step 2: Create the process tap
        var tapObjectID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapObjectID)
        guard tapStatus == noErr else {
            throw SystemAudioCaptureError.tapCreationFailed(tapStatus)
        }
        self.tapID = tapObjectID

        // Step 3: Get default output device UID
        let outputDeviceUID = try getDefaultOutputDeviceUID()

        // Step 4: Create aggregate device with tap baked in
        let aggDeviceID = try createAggregateDevice(
            tapUUID: tapUUID,
            outputDeviceUID: outputDeviceUID
        )
        self.aggregateDeviceID = aggDeviceID

        // Step 5: Set up AVAudioEngine pointed at the aggregate device
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Point the engine's input at our aggregate device
        try inputNode.auAudioUnit.setDeviceID(aggDeviceID)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            cleanup()
            throw SystemAudioCaptureError.invalidFormat
        }

        let stream = AsyncStream<TaggedAudioBuffer> { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.stopCapture() }
            }
        }

        let startTime = ProcessInfo.processInfo.systemUptime

        // Step 6: Install tap to receive buffers
        let cont = self.continuation
        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: inputFormat
        ) { buffer, _ in
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let tagged = TaggedAudioBuffer(
                buffer: buffer,
                source: .system,
                timestamp: elapsed
            )
            cont?.yield(tagged)
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.isCapturing = true

        LogManager.send("System audio capture started", category: .audio)
        return stream
    }

    func stopCapture() {
        guard isCapturing else { return }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        continuation?.finish()
        continuation = nil

        cleanup()
        isCapturing = false
        LogManager.send("System audio capture stopped", category: .audio)
    }

    var capturing: Bool {
        isCapturing
    }

    // MARK: - Private Helpers

    private func emitBuffer(_ buffer: TaggedAudioBuffer) {
        continuation?.yield(buffer)
    }

    private func cleanup() {
        // Destroy in reverse order: aggregate device first, then tap
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func getDefaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else {
            throw SystemAudioCaptureError.outputDeviceFailed(status)
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.stride)

        status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else {
            throw SystemAudioCaptureError.outputDeviceFailed(status)
        }

        return uid as String
    }

    private func createAggregateDevice(
        tapUUID: UUID,
        outputDeviceUID: String
    ) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "GreyEminence Capture",
            kAudioAggregateDeviceUIDKey as String: "com.greyeminence.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: tapUUID.uuidString,
                ],
            ],
        ]

        var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &aggregateDeviceID
        )
        guard status == noErr else {
            throw SystemAudioCaptureError.aggregateDeviceFailed(status)
        }

        return aggregateDeviceID
    }
}

enum SystemAudioCaptureError: Error, LocalizedError {
    case alreadyCapturing
    case tapCreationFailed(OSStatus)
    case outputDeviceFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            "System audio capture is already active"
        case .tapCreationFailed(let s):
            "Failed to create audio tap (OSStatus: \(s)). Audio capture permission may be required."
        case .outputDeviceFailed(let s):
            "Failed to read default output device (OSStatus: \(s))"
        case .aggregateDeviceFailed(let s):
            "Failed to create aggregate device (OSStatus: \(s))"
        case .invalidFormat:
            "Invalid audio format from system tap"
        }
    }
}

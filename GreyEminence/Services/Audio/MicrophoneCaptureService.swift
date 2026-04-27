import AVFoundation
import os

actor MicrophoneCaptureService {
    private var audioEngine: AVAudioEngine?
    private var isCapturing = false
    private var continuation: AsyncStream<TaggedAudioBuffer>.Continuation?

    /// Last buffer delivery timestamp, updated from the audio tap on a
    /// non-actor thread. The watchdog reads this synchronously to detect a
    /// stuck capture (IOProc stopped firing — route change, sleep/wake,
    /// tap revoked) without hopping actors per buffer.
    private let lastBufferAt = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// Last input format observed from the engine's input node. Set on
    /// startCapture so callers (and the watchdog) can react to format
    /// changes.
    nonisolated(unsafe) private var lastStartedFormat: AVAudioFormat?

    let bufferSize: AVAudioFrameCount = 4096

    /// Timestamp of the most recent buffer delivered from the audio tap.
    /// `nil` until the first buffer arrives. Safe to call from any isolation.
    nonisolated var lastBufferTimestamp: Date? {
        lastBufferAt.withLock { $0 }
    }

    /// Start capturing microphone audio, returning an AsyncStream of tagged
    /// buffers. If `deviceUID` is nil, falls back to the persisted user
    /// preference (`audio.preferredInputDeviceUID`) so the same Yeti / built-
    /// in choice survives launches and unplugs.
    func startCapture(deviceUID: String? = nil) throws -> AsyncStream<TaggedAudioBuffer> {
        guard !isCapturing else {
            throw MicCaptureError.alreadyCapturing
        }

        let engine = AVAudioEngine()

        let resolvedUID = deviceUID ?? UserDefaults.standard.string(forKey: "audio.preferredInputDeviceUID")
        if let resolvedUID, !resolvedUID.isEmpty {
            let applied = setInputDevice(uid: resolvedUID, on: engine)
            if applied {
                LogManager.send("Mic capture using preferred device UID \(resolvedUID)", category: .audio)
            } else {
                LogManager.send("Preferred mic device \(resolvedUID) not available — falling back to system default", category: .audio, level: .warning)
            }
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            throw MicCaptureError.noInputDevice
        }

        let stream = AsyncStream<TaggedAudioBuffer> { continuation in
            self.continuation = continuation

            continuation.onTermination = { @Sendable _ in
                Task { await self.stopCapture() }
            }
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        let cont = self.continuation
        let lastBuffer = self.lastBufferAt
        self.lastStartedFormat = inputFormat

        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: inputFormat
        ) { buffer, _ in
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let tagged = TaggedAudioBuffer(
                buffer: buffer,
                source: .microphone,
                timestamp: elapsed
            )
            lastBuffer.withLock { $0 = Date() }
            cont?.yield(tagged)
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.isCapturing = true

        LogManager.send("Microphone capture started", category: .audio)
        return stream
    }

    func suspendCapture() {
        guard isCapturing else { return }
        audioEngine?.pause()
        LogManager.send("Microphone capture suspended", category: .audio)
    }

    func resumeCapture() {
        guard isCapturing, let engine = audioEngine else { return }
        try? engine.start()
        LogManager.send("Microphone capture resumed", category: .audio)
    }

    func stopCapture() {
        guard isCapturing else { return }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        continuation?.finish()
        continuation = nil
        isCapturing = false
        LogManager.send("Microphone capture stopped", category: .audio)
    }

    var capturing: Bool {
        isCapturing
    }

    private func emitBuffer(_ buffer: TaggedAudioBuffer) {
        continuation?.yield(buffer)
    }

    @discardableResult
    private nonisolated func setInputDevice(uid: String, on engine: AVAudioEngine) -> Bool {
        var deviceID: AudioDeviceID = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uidCF = uid as CFString
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            UInt32(MemoryLayout<CFString>.size),
            &uidCF,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0, deviceID != kAudioObjectUnknown else { return false }

        var inputDeviceID = deviceID
        let setStatus = AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &inputDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return setStatus == noErr
    }
}

enum MicCaptureError: Error, LocalizedError {
    case alreadyCapturing
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing: "Microphone capture is already active"
        case .noInputDevice: "No microphone input device available"
        }
    }
}

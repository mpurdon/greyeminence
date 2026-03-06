import AVFoundation
import CoreAudio

/// Captures system audio using Core Audio Taps (macOS 14.2+).
///
/// Architecture:
/// 1. Create CATapDescription for all system audio output
/// 2. Create an AudioHardwareTap from the description (with a known UUID)
/// 3. Read the tap's native format via kAudioTapPropertyFormat
/// 4. Get the default output device UID
/// 5. Create an aggregate device linking the tap (via UUID) and output device
/// 6. Set up an IOProc callback on the aggregate device to receive audio buffers
///
/// Requires NSAudioCaptureUsageDescription in Info.plist.
/// The system will prompt the user for permission on first recording attempt.
actor SystemAudioCaptureService {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var isCapturing = false
    private var continuation: AsyncStream<TaggedAudioBuffer>.Continuation?

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

        // Step 3: Read the tap's native audio format
        var tapStreamDesc = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(
            tapObjectID, &formatAddress, 0, nil, &formatSize, &tapStreamDesc
        )
        guard formatStatus == noErr else {
            cleanup()
            throw SystemAudioCaptureError.tapFormatFailed(formatStatus)
        }

        guard let tapFormat = AVAudioFormat(streamDescription: &tapStreamDesc) else {
            cleanup()
            throw SystemAudioCaptureError.invalidFormat
        }

        LogManager.send(
            "System tap format: \(Int(tapFormat.sampleRate))Hz, \(tapFormat.channelCount)ch, \(tapFormat.isInterleaved ? "interleaved" : "non-interleaved")",
            category: .audio
        )

        // Step 4: Get default output device UID
        let outputDeviceUID = try getDefaultOutputDeviceUID()

        // Step 5: Create aggregate device with tap baked in
        let aggDeviceID = try createAggregateDevice(
            tapUUID: tapUUID,
            outputDeviceUID: outputDeviceUID
        )
        self.aggregateDeviceID = aggDeviceID

        // Step 6: Set up the async stream
        let stream = AsyncStream<TaggedAudioBuffer> { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.stopCapture() }
            }
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        let cont = self.continuation
        let format = tapFormat

        // Step 7: Create IOProc callback on the aggregate device
        var procID: AudioDeviceIOProcID?
        let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggDeviceID,
            nil  // run on Core Audio I/O thread
        ) { _, inInputData, _, _, _ in
            // Wrap the hardware buffer (zero-copy, valid only during this callback)
            guard let tempBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }

            let frameCount = tempBuffer.frameLength
            guard frameCount > 0 else { return }

            // Copy into an owned buffer (hardware buffer is only valid during this callback)
            guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            copiedBuffer.frameLength = frameCount

            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: tempBuffer.audioBufferList))
            let dst = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)
            for i in 0..<min(src.count, dst.count) {
                if let srcData = src[i].mData, let dstData = dst[i].mData {
                    memcpy(dstData, srcData, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
                }
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let tagged = TaggedAudioBuffer(buffer: copiedBuffer, source: .system, timestamp: elapsed)
            cont?.yield(tagged)
        }

        guard ioProcStatus == noErr, let procID else {
            cleanup()
            throw SystemAudioCaptureError.ioProcFailed(ioProcStatus)
        }
        self.deviceProcID = procID

        // Step 8: Start the aggregate device (begins calling the IOProc)
        let startStatus = AudioDeviceStart(aggDeviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggDeviceID, procID)
            self.deviceProcID = nil
            cleanup()
            throw SystemAudioCaptureError.deviceStartFailed(startStatus)
        }

        self.isCapturing = true
        LogManager.send("System audio capture started", category: .audio)
        return stream
    }

    func stopCapture() {
        guard isCapturing else { return }

        if let deviceProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
        }
        self.deviceProcID = nil

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
    case tapFormatFailed(OSStatus)
    case outputDeviceFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            "System audio capture is already active"
        case .tapCreationFailed(let s):
            "Failed to create audio tap (OSStatus: \(s)). Audio capture permission may be required."
        case .tapFormatFailed(let s):
            "Failed to read tap format (OSStatus: \(s))"
        case .outputDeviceFailed(let s):
            "Failed to read default output device (OSStatus: \(s))"
        case .aggregateDeviceFailed(let s):
            "Failed to create aggregate device (OSStatus: \(s))"
        case .ioProcFailed(let s):
            "Failed to create audio I/O proc (OSStatus: \(s))"
        case .deviceStartFailed(let s):
            "Failed to start aggregate device (OSStatus: \(s))"
        case .invalidFormat:
            "Invalid audio format from system tap"
        }
    }
}

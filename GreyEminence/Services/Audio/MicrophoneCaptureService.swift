import AVFoundation

actor MicrophoneCaptureService {
    private var audioEngine: AVAudioEngine?
    private var isCapturing = false
    private var continuation: AsyncStream<TaggedAudioBuffer>.Continuation?

    let bufferSize: AVAudioFrameCount = 4096

    /// Start capturing microphone audio, returning an AsyncStream of tagged buffers.
    func startCapture(deviceUID: String? = nil) throws -> AsyncStream<TaggedAudioBuffer> {
        guard !isCapturing else {
            throw MicCaptureError.alreadyCapturing
        }

        let engine = AVAudioEngine()

        // Set specific input device if requested
        if let deviceUID {
            setInputDevice(uid: deviceUID, on: engine)
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
            cont?.yield(tagged)
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.isCapturing = true

        LogManager.send("Microphone capture started", category: .audio)
        return stream
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

    private nonisolated func setInputDevice(uid: String, on engine: AVAudioEngine) {
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

        guard status == noErr else { return }

        // Set the input device on the audio unit
        var inputDeviceID = deviceID
        AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &inputDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
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

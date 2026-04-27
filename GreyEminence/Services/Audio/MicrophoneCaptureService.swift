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

        // Log the actual input device name + mute/volume so silent recordings
        // are diagnosable. Yeti's hardware mute, input volume at 0, or "Mute"
        // pressed in System Settings → Sound all produce zero-amplitude
        // buffers without any obvious failure mode.
        let probe = Self.probeInputDevice(engine: engine)
        LogManager.send(
            "Mic device: \(probe.name ?? "unknown") · volume \(probe.volumeDescription) · \(probe.muteDescription)",
            category: .audio,
            level: probe.isLikelySilent ? .warning : .info
        )

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

    struct DeviceProbe {
        var name: String?
        var inputVolume: Float?  // 0.0–1.0 if the device exposes the property
        var isMuted: Bool?

        var volumeDescription: String {
            guard let v = inputVolume else { return "vol n/a" }
            return "vol \(String(format: "%.2f", v))"
        }
        var muteDescription: String {
            switch isMuted {
            case .some(true): return "MUTED"
            case .some(false): return "unmuted"
            case .none: return "mute n/a"
            }
        }
        var isLikelySilent: Bool {
            (isMuted == true) || (inputVolume == 0)
        }
    }

    nonisolated private static func probeInputDevice(engine: AVAudioEngine) -> DeviceProbe {
        var probe = DeviceProbe()
        guard let unit = engine.inputNode.audioUnit else { return probe }

        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let getStatus = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard getStatus == noErr, deviceID != 0 else { return probe }

        // Name
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name) == noErr,
           let cfName = name?.takeRetainedValue() {
            probe.name = cfName as String
        }

        // Mute (input scope, master element)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteVal: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &muteSize, &muteVal) == noErr {
            probe.isMuted = muteVal != 0
        }

        // Volume — try master element first, then channel 1.
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol: Float32 = 0
        var volSize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &volSize, &vol) == noErr {
            probe.inputVolume = vol
        } else {
            volAddr.mElement = 1
            if AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &volSize, &vol) == noErr {
                probe.inputVolume = vol
            }
        }
        return probe
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

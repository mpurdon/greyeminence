import AVFoundation

extension Notification.Name {
    /// Posted when a recording starts capturing the microphone. The level
    /// monitor observes this and pauses so two AVAudioEngines in the same
    /// process don't fight for the same input device (which results in
    /// silent buffers for the second one).
    static let geMicCaptureWillStart = Notification.Name("ge.mic.capture.willStart")
    static let geMicCaptureDidEnd = Notification.Name("ge.mic.capture.didEnd")
}

@Observable
@MainActor
final class MicLevelMonitor {
    var level: Float = 0
    var gain: Float = 1.0

    private var audioEngine: AVAudioEngine?
    private var isMonitoring = false
    private var pausedDeviceUID: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .geMicCaptureWillStart, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pauseForRecording() }
        })
        observers.append(nc.addObserver(forName: .geMicCaptureDidEnd, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeAfterRecording() }
        })
    }

    deinit {
        // observers is a stored property; notifications carry weak self so
        // expired refs no-op. Explicit removal isn't required pre-Swift 6
        // strict-actor isolation rules; left intentionally empty.
    }

    private func pauseForRecording() {
        guard isMonitoring else { return }
        pausedDeviceUID = audioEngine?.inputNode.audioUnit.flatMap(Self.currentDeviceUID(for:)) ?? ""
        stopMonitoring()
    }

    private func resumeAfterRecording() {
        guard pausedDeviceUID != nil else { return }
        let uid = pausedDeviceUID
        pausedDeviceUID = nil
        startMonitoring(deviceUID: uid?.isEmpty == false ? uid : nil)
    }

    func startMonitoring(deviceUID: String? = nil) {
        stopMonitoring()

        let engine = AVAudioEngine()

        if let deviceUID {
            Self.setInputDevice(uid: deviceUID, on: engine)
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        // Handler is @Sendable so the closure doesn't inherit MainActor isolation
        Self.installMeterTap(on: inputNode, format: format) { [weak self] rms in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.level = min(rms * self.gain, 1.0)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
            isMonitoring = true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isMonitoring = false
        level = 0
    }

    /// Installs the audio tap in a nonisolated context so the closure
    /// does not inherit MainActor isolation (which would crash on the realtime audio thread).
    private nonisolated static func installMeterTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        handler: @escaping @Sendable (Float) -> Void
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            handler(calculateRMS(buffer))
        }
    }

    private nonisolated static func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[0][i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        return min(rms * 5, 1.0)
    }

    nonisolated private static func currentDeviceUID(for unit: AudioUnit) -> String? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size) == noErr,
              deviceID != 0 else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &uidSize, &uid) == noErr,
              let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private nonisolated static func setInputDevice(uid: String, on engine: AVAudioEngine) {
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

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
    /// Buffers handed to the stream by the tap; see `SystemAudioCaptureService`.
    private let delivered = OSAllocatedUnfairLock<Int>(initialState: 0)

    nonisolated var deliveredBufferCount: Int {
        delivered.withLock { $0 }
    }

    let bufferSize: AVAudioFrameCount = 4096

    /// Uptime at which this capture began. Preserved across engine rebuilds so
    /// buffer timestamps stay on one continuous timeline — a recovery must not
    /// restart segment times at zero.
    private var captureStartUptime: Double = 0
    private var requestedDeviceUID: String?
    private var configChangeObserver: NSObjectProtocol?
    /// Bounded so a device that can never deliver doesn't spin forever.
    private var recoveryAttempts = 0
    private static let maxRecoveryAttempts = 5

    /// When the engine was last built. Starting an engine (and setting the
    /// input AU's CurrentDevice) itself posts a configuration change, so
    /// changes arriving right after a build are our own doing and must be
    /// ignored — otherwise the observer feeds itself in a loop.
    private var lastEngineBuildAt: Date = .distantPast
    private static let buildSettleWindow: TimeInterval = 3

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

        // Tell any other AVAudioEngine in the process (e.g. the Settings
        // mic-level monitor) to release the input device. Two engines tapping
        // the same input deliver silence to whichever started second on macOS.
        MicCaptureGate.set(true)
        NotificationCenter.default.post(name: .geMicCaptureWillStart, object: nil)
        // Brief yield so observers process the notification before we claim the device.
        Thread.sleep(forTimeInterval: 0.05)

        self.requestedDeviceUID = deviceUID
        self.captureStartUptime = ProcessInfo.processInfo.systemUptime
        self.recoveryAttempts = 0
        delivered.withLock { $0 = 0 }

        let stream = AsyncStream<TaggedAudioBuffer> { continuation in
            self.continuation = continuation

            continuation.onTermination = { @Sendable _ in
                Task { await self.stopCapture() }
            }
        }

        let engine = try buildEngine()
        self.audioEngine = engine
        self.isCapturing = true
        observeConfigurationChanges(on: engine)

        LogManager.send("Microphone capture started", category: .audio)
        return stream
    }

    /// Builds the engine, installs the tap into the *existing* continuation,
    /// and starts it. Shared by `startCapture` and recovery so a rebuilt
    /// engine is configured identically to the original.
    private func buildEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()

        let resolvedUID = requestedDeviceUID
            ?? UserDefaults.standard.string(forKey: AudioSessionManager.preferredUIDKey)
        if let resolvedUID, !resolvedUID.isEmpty {
            // Skip the AudioUnitSetProperty call when the preferred UID is
            // already the system default input. Setting CurrentDevice on the
            // input AU triggers an AU re-init that disrupts any other tap
            // (e.g. Settings level monitor) on the same device, leading to
            // silent buffers — the very bug v0.9.59 introduced. If our
            // preference matches what AVAudioEngine would pick anyway, leave
            // the AU alone.
            if let defaultUID = Self.currentDefaultInputDeviceUID(), defaultUID == resolvedUID {
                LogManager.send("Mic capture: preferred device matches system default (\(resolvedUID)) — using engine default path", category: .audio)
            } else {
                let applied = setInputDevice(uid: resolvedUID, on: engine)
                if applied {
                    LogManager.send("Mic capture using preferred device UID \(resolvedUID)", category: .audio)
                } else {
                    LogManager.send("Preferred mic device \(resolvedUID) not available — falling back to system default", category: .audio, level: .warning)
                }
            }
        }

        let inputNode = engine.inputNode
        // Defensive: explicitly enable IO on the input bus. AVAudioEngine is
        // supposed to do this when you install a tap, but in some macOS
        // states (e.g. after the app's TCC record was just changed, or after
        // another engine in the same process disabled it) the bus is left
        // disabled and every buffer comes through as silence.
        Self.forceEnableInputIO(on: engine)

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

        let startTime = self.captureStartUptime
        let cont = self.continuation
        let lastBuffer = self.lastBufferAt
        let deliveredCount = self.delivered
        // A rebuilt engine continues the same capture, so the count carries on.

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
            deliveredCount.withLock { $0 += 1 }
            cont?.yield(tagged)
        }

        engine.prepare()
        try engine.start()
        lastEngineBuildAt = Date()
        return engine
    }

    enum RecoveryOutcome {
        /// Nothing was wrong, or it is too soon to try again.
        case notNeeded
        case recovered
        /// Tried and could not rebuild, or the attempt budget is spent.
        case failed
    }

    /// Rebuilds only when the tap has genuinely stopped delivering. A
    /// configuration change on its own is not a fault — the device format can
    /// change while audio keeps flowing, and the engine we just started emits
    /// one as a matter of course.
    ///
    /// The single entry point for both triggers (the configuration-change
    /// observer and the watchdog), so the stall threshold, settle window, and
    /// retry cadence are defined once, here, next to the attempt budget.
    @discardableResult
    func recoverIfStalled(reason: String) -> RecoveryOutcome {
        guard isCapturing else { return .notNeeded }
        guard Self.shouldRecoverOnConfigChange(
            now: Date(),
            lastEngineBuildAt: lastEngineBuildAt,
            lastBufferAt: lastBufferTimestamp
        ) else { return .notNeeded }
        guard recoveryAttempts < Self.maxRecoveryAttempts else { return .failed }
        return recoverCapture(reason: reason) ? .recovered : .failed
    }

    /// Whether a configuration-change notification warrants rebuilding.
    ///
    /// Pure so the two ways this can go wrong are covered by tests: rebuilding
    /// in response to our own build (an infinite loop — observed 2026-08-05,
    /// five rebuilds in under a second) and rebuilding while audio is still
    /// flowing (a needless gap in the recording).
    static func shouldRecoverOnConfigChange(
        now: Date,
        lastEngineBuildAt: Date,
        lastBufferAt: Date?,
        settleWindow: TimeInterval = buildSettleWindow,
        bufferStaleAfter: TimeInterval = 3
    ) -> Bool {
        guard now.timeIntervalSince(lastEngineBuildAt) >= settleWindow else { return false }
        guard let lastBufferAt else { return true }   // never delivered — rebuild
        return now.timeIntervalSince(lastBufferAt) >= bufferStaleAfter
    }

    /// macOS posts this when the input hardware or its format changes under
    /// the engine — which is what happens when another app (Teams, Zoom,
    /// Discord) claims the input device moments after we started. The engine
    /// stops and the tap is torn down; without reinstalling, buffers simply
    /// never resume and the recording captures only the far end.
    private func observeConfigurationChanges(on engine: AVAudioEngine) {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.recoverIfStalled(reason: "engine configuration changed") }
        }
    }

    /// Rebuilds the engine and tap, feeding the same continuation so consumers
    /// never see the interruption. Returns true when capture was restarted.
    @discardableResult
    func recoverCapture(reason: String) -> Bool {
        guard isCapturing else { return false }
        guard recoveryAttempts < Self.maxRecoveryAttempts else {
            LogManager.send(
                "Mic capture not recovered (\(reason)) — gave up after \(Self.maxRecoveryAttempts) attempts",
                category: .audio,
                level: .warning
            )
            return false
        }
        recoveryAttempts += 1

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        do {
            let engine = try buildEngine()
            audioEngine = engine
            observeConfigurationChanges(on: engine)
            LogManager.send(
                "Mic capture recovered (\(reason)) — attempt \(recoveryAttempts)",
                category: .audio
            )
            return true
        } catch {
            LogManager.send(
                "Mic capture recovery failed (\(reason)): \(error.localizedDescription)",
                category: .audio,
                level: .warning
            )
            return false
        }
    }

    /// Cleared by the watchdog once buffers are flowing again, so a later
    /// unrelated stall gets a fresh budget.
    func noteHealthy() {
        recoveryAttempts = 0
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

        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        continuation?.finish()
        continuation = nil
        isCapturing = false
        MicCaptureGate.set(false)
        NotificationCenter.default.post(name: .geMicCaptureDidEnd, object: nil)
        LogManager.send("Microphone capture stopped", category: .audio)
    }

    nonisolated private static func currentDefaultInputDeviceUID() -> String? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
              let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    nonisolated private static func forceEnableInputIO(on engine: AVAudioEngine) {
        guard let unit = engine.inputNode.audioUnit else { return }
        var enable: UInt32 = 1
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,  // input bus
            &enable,
            UInt32(MemoryLayout<UInt32>.size)
        )
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

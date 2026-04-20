import AVFoundation
import Foundation

/// Watches for other apps using the microphone (Teams call, Zoom, Meet-in-browser,
/// FaceTime, etc.) and signals when a meeting likely started or ended. We only poll
/// when enabled, so there is no cost when the user has auto-start disabled.
///
/// The service is driven by explicit `note*` calls from `RecordingViewModel` so it
/// understands whether the current recording is auto-started (and should auto-stop
/// when the call ends) or manually started (user is in control — stay out of the way).
@Observable
@MainActor
final class MeetingDetectionService {
    enum Mode {
        case disabled
        case armedForStart
        case trackingAutoRun
        case passive
    }

    private(set) var mode: Mode = .disabled
    private(set) var externalMicInUse: Bool = false

    private let startDebounce: TimeInterval = 10
    private let stopDebounce: TimeInterval = 60
    private let pollInterval: TimeInterval = 2

    private var timer: Timer?
    private var inUseSince: Date?
    private var clearSince: Date?
    /// Set when the user manually stops mid-call. Blocks auto-start until the
    /// external mic-in-use signal has cleared, so we don't re-record the same
    /// meeting they just told us to stop recording.
    private var waitingForMicClear: Bool = false

    var onStartRequested: (() -> Void)?
    var onStopRequested: (() -> Void)?

    func enable() {
        guard mode == .disabled else { return }
        mode = .armedForStart
        resetTimings()
        startTimer()
        LogManager.send("Meeting auto-detection enabled", category: .audio)
    }

    func disable() {
        mode = .disabled
        timer?.invalidate()
        timer = nil
        resetTimings()
        waitingForMicClear = false
        externalMicInUse = false
        LogManager.send("Meeting auto-detection disabled", category: .audio)
    }

    func noteManualStart() {
        guard mode != .disabled else { return }
        mode = .passive
        resetTimings()
    }

    func noteAutoStart() {
        guard mode != .disabled else { return }
        mode = .trackingAutoRun
        resetTimings()
    }

    func noteManualStop() {
        guard mode != .disabled else { return }
        mode = .armedForStart
        waitingForMicClear = queryMicInUse()
        resetTimings()
    }

    func noteAutoStop() {
        guard mode != .disabled else { return }
        mode = .armedForStart
        waitingForMicClear = false
        resetTimings()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer = t
    }

    private func resetTimings() {
        inUseSince = nil
        clearSince = nil
    }

    private func tick() {
        guard mode != .disabled else { return }
        let inUse = queryMicInUse()
        externalMicInUse = inUse

        switch mode {
        case .armedForStart:
            handleArmed(inUse: inUse)
        case .trackingAutoRun:
            handleTracking(inUse: inUse)
        case .passive, .disabled:
            break
        }
    }

    private func handleArmed(inUse: Bool) {
        if waitingForMicClear {
            if !inUse {
                waitingForMicClear = false
            }
            return
        }
        if inUse {
            clearSince = nil
            if inUseSince == nil { inUseSince = Date() }
            guard let since = inUseSince else { return }
            if Date().timeIntervalSince(since) >= startDebounce {
                LogManager.send("Auto-detected meeting start (mic in use by other app)", category: .audio)
                onStartRequested?()
            }
        } else {
            inUseSince = nil
        }
    }

    private func handleTracking(inUse: Bool) {
        if !inUse {
            inUseSince = nil
            if clearSince == nil { clearSince = Date() }
            guard let since = clearSince else { return }
            if Date().timeIntervalSince(since) >= stopDebounce {
                LogManager.send("Auto-detected meeting end (mic clear for \(Int(stopDebounce))s)", category: .audio)
                onStopRequested?()
            }
        } else {
            clearSince = nil
        }
    }

    private func queryMicInUse() -> Bool {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        for device in session.devices {
            if device.isInUseByAnotherApplication { return true }
        }
        return false
    }
}

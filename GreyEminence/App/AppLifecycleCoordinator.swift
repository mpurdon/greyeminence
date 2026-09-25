import AppKit
import SwiftData

/// Wires the macOS lifecycle hooks SwiftUI doesn't expose directly:
/// - `applicationShouldTerminate` so Cmd-Q during a recording flushes the
///   audio + transcript before the process dies (otherwise the active m4a
///   chunk goes unfinalized and the last ~10s are lost).
/// - `NSWorkspace` sleep/wake notifications so a long recording doesn't
///   silently lose system audio when the lid closes — we pause on sleep and
///   resume on wake.
@MainActor
final class AppLifecycleCoordinator: NSObject, NSApplicationDelegate {
    private weak var recordingViewModel: RecordingViewModel?
    private var modelContextProvider: (() -> ModelContext?)?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var wasRecordingBeforeSleep = false

    func bind(recordingViewModel: RecordingViewModel, modelContextProvider: @escaping () -> ModelContext?) {
        self.recordingViewModel = recordingViewModel
        self.modelContextProvider = modelContextProvider
        registerSleepWakeObservers()
    }

    // MARK: - Launch

    /// Before any window or launch-time recovery: a development build and
    /// the released one must not run on the same data at once.
    func applicationWillFinishLaunching(_ notification: Notification) {
        InstanceGuard.check()
    }

    // MARK: - Termination

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = recordingViewModel,
              vm.state == .recording || vm.state == .paused else {
            return .terminateNow
        }

        LogManager.send("Termination requested while recording — flushing", category: .general)
        Task { @MainActor in
            await vm.flushForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Sleep / wake

    private func registerSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillSleep()
            }
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidWake()
            }
        }
    }

    private func handleWillSleep() {
        guard let vm = recordingViewModel, vm.state == .recording else { return }
        wasRecordingBeforeSleep = true
        LogManager.send("System going to sleep — pausing recording", category: .audio)
        vm.pauseRecording()
    }

    private func handleDidWake() {
        guard wasRecordingBeforeSleep,
              let vm = recordingViewModel,
              vm.state == .paused else {
            wasRecordingBeforeSleep = false
            return
        }
        wasRecordingBeforeSleep = false
        LogManager.send("System woke — resuming recording", category: .audio)
        vm.resumeRecording()
    }

    // No deinit cleanup: this delegate's lifetime matches the app process,
    // so the system reclaims the observers when the process exits.
}

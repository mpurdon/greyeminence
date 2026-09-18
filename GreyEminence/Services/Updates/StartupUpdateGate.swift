import Foundation

/// Holds the rest of launch until the update check has answered.
///
/// `GreyEminenceApp` fires an appcast check the moment the updater starts,
/// but nothing used to wait for it: maintenance rewrote rows, auto-detection
/// started recordings, the AI tidy-up spent a call — and then Sparkle's
/// "Install and Relaunch" landed on top of all of it. The launch sequence in
/// `ContentView` now awaits `waitForDecision()` first, so an update installs
/// over an idle app, and a launch with no update loses only the round trip
/// to the appcast.
///
/// Two phases, each capped so a launch never hangs on the network or on a
/// dialog nobody is looking at:
/// - **checking** — the appcast fetch. Released by "up to date", an error,
///   or `checkTimeout`.
/// - **awaitingChoice** — an update was shown. Released by Skip / Remind Me
///   Later, by an install that fails, or by `choiceTimeout`. An install that
///   succeeds never releases: the app is about to relaunch.
@MainActor
final class StartupUpdateGate {
    static let shared = StartupUpdateGate()

    enum Outcome: Equatable, Sendable {
        /// Updates are not checked in this build (Debug) or were deferred.
        case notChecked
        case upToDate
        case updateDeclined
        case checkFailed
        case timedOut
    }

    private enum Phase: Equatable {
        case checking
        case awaitingChoice
        case installing
        case decided(Outcome)
    }

    /// Appcast fetch budget. GitHub answers in well under two seconds;
    /// ten covers a slow link without making an offline launch feel hung.
    nonisolated static let checkTimeout: Duration = .seconds(10)
    /// How long a shown update alert may sit unanswered before launch
    /// proceeds behind it.
    nonisolated static let choiceTimeout: Duration = .seconds(120)

    private var phase: Phase = .checking
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// The app uses `shared`; tests build their own so nothing leaks between
    /// cases.
    init() {}

    var outcome: Outcome? {
        if case .decided(let outcome) = phase { return outcome }
        return nil
    }

    // MARK: - Updater events

    /// The check will not run at all — release immediately.
    func checkSkipped() {
        decide(.notChecked)
    }

    func noUpdateFound() {
        decide(.upToDate)
    }

    func checkFailed() {
        decide(.checkFailed)
    }

    /// An update alert is on screen: stop the check clock, start the
    /// choice clock.
    func updateFound() {
        guard phase == .checking else { return }
        phase = .awaitingChoice
    }

    /// The update was found but Sparkle will not show it now (recording in
    /// progress). Nothing to wait for.
    func updateDeferred() {
        guard phase == .checking || phase == .awaitingChoice else { return }
        decide(.notChecked)
    }

    func userDeclinedUpdate() {
        guard phase == .awaitingChoice else { return }
        decide(.updateDeclined)
    }

    /// The user chose Install. Stay closed — the app is relaunching. If the
    /// install later fails, `installFailed` reopens the gate.
    func userChoseInstall() {
        guard phase == .awaitingChoice else { return }
        phase = .installing
    }

    func installFailed() {
        guard phase == .installing || phase == .awaitingChoice else { return }
        decide(.checkFailed)
    }

    // MARK: - Waiting

    /// Suspends until the gate decides, or the phase's timeout passes.
    /// Returns at once if it has already decided.
    func waitForDecision(
        checkTimeout: Duration = StartupUpdateGate.checkTimeout,
        choiceTimeout: Duration = StartupUpdateGate.choiceTimeout
    ) async -> Outcome {
        if let outcome { return outcome }

        // The check clock and the choice clock are independent: an update
        // found at second nine should still get its full window to be
        // answered.
        let clock = Task { @MainActor [weak self] in
            try? await Task.sleep(for: checkTimeout)
            guard let self, !Task.isCancelled else { return }
            if self.phase == .checking {
                LogManager.send("Update check did not answer within \(checkTimeout) — continuing launch", category: .update, level: .warning)
                self.decide(.timedOut)
                return
            }
            try? await Task.sleep(for: choiceTimeout)
            guard !Task.isCancelled, self.phase == .awaitingChoice else { return }
            LogManager.send("Update alert unanswered for \(choiceTimeout) — continuing launch behind it", category: .update)
            self.decide(.timedOut)
        }
        defer { clock.cancel() }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        return outcome ?? .timedOut
    }

    private func decide(_ outcome: Outcome) {
        if case .decided = phase { return }
        phase = .decided(outcome)
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

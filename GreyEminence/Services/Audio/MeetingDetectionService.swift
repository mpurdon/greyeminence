import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Watches for other apps using the microphone (Teams call, Zoom, Meet-in-browser,
/// FaceTime, etc.) and signals when a meeting likely started or ended. We only poll
/// when enabled, so there is no cost when the user has auto-start disabled.
///
/// The service is driven by explicit `noteStart`/`noteStop` calls from
/// `RecordingViewModel`. A recording is bound to the app whose call it is —
/// the one holding the microphone when it started, by any route — and ends
/// when that app lets go of the mic. A recording with nobody else on the mic
/// is a solo one; the user is in control and the detector stays out of the way.
@Observable
@MainActor
final class MeetingDetectionService {
    enum Mode {
        case disabled
        case armedForStart
        /// Recording, bound to `trackedHolder`. Ends when that app releases the mic.
        case tracking
        /// Recording with nothing to track: nobody else was on the mic when
        /// it started, or it was already running when detection was enabled.
        case passive
    }

    enum Origin {
        case manual
        case auto
    }

    /// A process other than us that currently has an active input IOProc.
    struct MicHolder: Sendable, Equatable {
        let pid: pid_t
        let bundleID: String?
        let appName: String?
        /// The microphone this process is capturing from, when Core Audio
        /// reports a real one. A call app that has the Yeti open reports the
        /// Yeti here, which is how the recorder ends up on the same device.
        var inputDevice: InputDevice? = nil
    }

    /// A real input device another process has open.
    struct InputDevice: Sendable, Equatable {
        let uid: String
        let name: String
    }

    /// Whether recordings should follow the call app's microphone rather
    /// than the device chosen in Settings. On by default: the whole point of
    /// recording a call is to hear what the call heard.
    static let followCallMicrophoneKey = "audio.followCallMicrophone"

    static var followsCallMicrophone: Bool {
        followsCallMicrophone(in: .standard)
    }

    static func followsCallMicrophone(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: followCallMicrophoneKey) as? Bool ?? true
    }

    /// The microphone to record from, given who is holding the mic.
    ///
    /// The holder the start policy would act on wins — that is the call —
    /// and any other holder with a real device is the fallback, since two
    /// apps listening at once are almost always on the same microphone.
    /// nil means nothing useful was learned and the Settings choice applies.
    static func captureDevice(for holders: [MicHolder]) -> InputDevice? {
        if let device = startDecision(for: holders).holder?.inputDevice {
            return device
        }
        return holders.lazy.compactMap(\.inputDevice).first
    }

    /// The app a recording made now is *of*: the call the start policy would
    /// act on, else whoever is on a real microphone, else anyone holding the
    /// mic. Stamped on the meeting as its source app and tracked so the
    /// recording ends when this app hangs up. nil is a solo recording.
    static func sourceHolder(for holders: [MicHolder]) -> MicHolder? {
        startDecision(for: holders).holder
            ?? holders.first(where: { $0.inputDevice != nil })
            ?? holders.first
    }

    /// Whether two holders are the same application. Bundle identity when we
    /// have it; the pid otherwise, for HAL-direct clients we cannot name.
    static func isSameApp(_ lhs: MicHolder, _ rhs: MicHolder) -> Bool {
        if let lhsID = lhs.bundleID, let rhsID = rhs.bundleID {
            return lhsID == rhsID
        }
        return lhs.pid == rhs.pid
    }

    private(set) var mode: Mode = .disabled
    private(set) var externalMicInUse: Bool = false

    /// The app the current recording is bound to, with the microphone it had
    /// open at the last poll. Followed across device changes — Teams opens
    /// the built-in mic first and moves to the chosen one a few seconds later
    /// — because a call switching microphones is still the same call.
    private(set) var trackedHolder: MicHolder?

    /// True while the 5s poll is running, so callers can prefer the cached
    /// `currentHolders` over a fresh Core Audio enumeration.
    var isPolling: Bool { mode != .disabled }

    /// Everything holding the mic as of the last poll. Read by
    /// `RecordingViewModel` to stamp source-app provenance on the meeting.
    private(set) var currentHolders: [MicHolder] = []

    private let startDebounce: TimeInterval = 10
    /// How long the tracked app must be off the microphone before the
    /// recording ends. 60 s while the rule was "nobody on the mic"; with one
    /// app tracked, 20 s rides out a Teams reconnect or device switch (the
    /// built-in→Yeti hop shows no gap at all) and a test call on 2026-09-14
    /// was stopped by hand 53 s after hang-up because nothing had happened.
    private let stopDebounce: TimeInterval = 20
    private let pollInterval: TimeInterval = 5

    private var timer: Timer?
    private var inUseSince: Date?
    private var clearSince: Date?

    /// Wall clock for the debounces; tests advance it by hand.
    var now: () -> Date = { Date() }
    /// Whether `enable` schedules the 5s Core Audio poll. Tests drive
    /// `apply(_:)` directly and leave coreaudiod alone.
    private let pollsAutomatically: Bool

    init(pollsAutomatically: Bool = true) {
        self.pollsAutomatically = pollsAutomatically
    }
    /// Set when the user manually stops mid-call. Blocks auto-start until the
    /// external mic-in-use signal has cleared, so we don't re-record the same
    /// meeting they just told us to stop recording.
    private var waitingForMicClear: Bool = false

    /// Last logged holder set, so the 5s poll logs only when the picture
    /// actually changes. Compared directly rather than via a formatted string,
    /// which would be rebuilt on every poll only to be thrown away.
    private var lastLoggedHolders: [MicHolder] = []

    /// True once we've asked about the current hold, so an ignored prompt
    /// doesn't reappear every poll. Cleared when the mic goes quiet.
    private var hasPromptedForCurrentHold = false

    var onStartRequested: (() -> Void)?
    var onStopRequested: (() -> Void)?
    /// The app this recording is bound to is now on a different microphone.
    /// The recorder moves its capture to match.
    var onSourceDeviceChanged: ((MicHolder) -> Void)?
    /// Raised instead of `onStartRequested` for apps that hold the mic
    /// outside of calls — the UI asks the user.
    var onConfirmationRequested: ((MicHolder) -> Void)?
    /// The call we asked about is over (or the app released the mic), so any
    /// prompt still on screen is stale and should be withdrawn.
    var onConfirmationExpired: (() -> Void)?

    func enable(currentlyRecording: Bool) {
        guard mode == .disabled else { return }
        mode = currentlyRecording ? .passive : .armedForStart
        resetTimings()
        if pollsAutomatically { startTimer() }
        LogManager.send("Meeting auto-detection enabled", category: .audio)
    }

    func disable() {
        mode = .disabled
        timer?.invalidate()
        timer = nil
        resetTimings()
        waitingForMicClear = false
        trackedHolder = nil
        if externalMicInUse { externalMicInUse = false }
        LogManager.send("Meeting auto-detection disabled", category: .audio)
    }

    /// A recording started, by any route, with `holders` on the microphone.
    ///
    /// Binds the recording to the call app among them (see `sourceHolder`)
    /// so it ends when that app hangs up — a recording the user started by
    /// hand mid-call is still a recording of that call. On 2026-09-14 a
    /// manual restart onto the right microphone ran 31 minutes past the end
    /// of the Teams call because only auto-started runs used to be tracked.
    func noteStart(holders: [MicHolder]) {
        guard mode != .disabled else { return }
        // Recording now — don't ask again about the hold we just acted on.
        hasPromptedForCurrentHold = true
        resetTimings()
        if let source = Self.sourceHolder(for: holders) {
            trackedHolder = source
            mode = .tracking
            LogManager.send(
                "Recording bound to \(Self.describe(source)) — stops when it releases the microphone",
                category: .audio
            )
        } else {
            trackedHolder = nil
            mode = .passive
        }
    }

    func noteStop(_ origin: Origin) {
        guard mode != .disabled else { return }
        mode = .armedForStart
        trackedHolder = nil
        waitingForMicClear = (origin == .manual) && queryMicInUse()
        resetTimings()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func resetTimings() {
        inUseSince = nil
        clearSince = nil
    }

    /// Set while a poll is in flight, so a slow CoreAudio round-trip cannot
    /// stack ticks on top of each other.
    private var pollInFlight = false

    private func tick() {
        guard mode != .disabled, !pollInFlight else { return }
        pollInFlight = true
        Task { [weak self] in
            let holders = await Self.holdersOffMainThread()
            guard let self else { return }
            self.pollInFlight = false
            self.apply(holders)
        }
    }

    /// One poll's worth of holders. Internal so the policy can be driven
    /// with synthetic holders in tests.
    func apply(_ holders: [MicHolder]) {
        guard mode != .disabled else { return }
        logHolderChange(holders)
        currentHolders = holders
        let inUse = !holders.isEmpty
        if externalMicInUse != inUse {
            externalMicInUse = inUse
        }
        // Leaving the channel (or ending the call) re-arms the prompt, so the
        // next call asks again — and withdraws any prompt still on screen,
        // which now refers to a call that is over.
        if !inUse, hasPromptedForCurrentHold {
            hasPromptedForCurrentHold = false
            onConfirmationExpired?()
        }

        switch mode {
        case .armedForStart:
            handleArmed(holders: holders)
        case .tracking:
            // Deliberately keyed off mic-held only, never voice activity: a
            // long silence mid-call must not end the recording.
            handleTracking(holders: holders)
        case .passive, .disabled:
            break
        }
    }

    private func handleArmed(holders: [MicHolder]) {
        if waitingForMicClear {
            if holders.isEmpty { waitingForMicClear = false }
            return
        }
        let decision = Self.startDecision(for: holders)
        guard let holder = decision.holder else {
            inUseSince = nil
            return
        }
        clearSince = nil
        if inUseSince == nil { inUseSince = now() }
        guard let since = inUseSince else { return }
        let debounce = decision.debounce ?? startDebounce
        guard now().timeIntervalSince(since) >= debounce else { return }

        let who = holder.appName ?? holder.bundleID ?? "another app"
        switch decision {
        case .start:
            LogManager.send("Auto-detected meeting start (\(who))", category: .audio)
            onStartRequested?()
        case .confirm:
            // Once per hold: an ignored prompt must not come back every poll.
            guard !hasPromptedForCurrentHold else { return }
            hasPromptedForCurrentHold = true
            LogManager.send("Asking whether to record \(who) call", category: .audio)
            onConfirmationRequested?(holder)
        case .none:
            break
        }
    }

    /// What to do about the current set of mic holders.
    ///
    /// Pure so the policy can be tested without Core Audio. Apps whose profile
    /// sets `requiresConfirmation` produce `.confirm`; everything else
    /// produces `.start` on mic-held alone, exactly as before profiles existed.
    enum StartDecision: Equatable {
        case none
        case start(holder: MicHolder, debounce: TimeInterval?)
        case confirm(holder: MicHolder, debounce: TimeInterval?)

        var holder: MicHolder? {
            switch self {
            case .none: nil
            case .start(let holder, _), .confirm(let holder, _): holder
            }
        }

        var debounce: TimeInterval? {
            switch self {
            case .none: nil
            case .start(_, let debounce), .confirm(_, let debounce): debounce
            }
        }
    }

    static func startDecision(for holders: [MicHolder]) -> StartDecision {
        // A holder that can start on its own wins over one that needs asking,
        // so a Teams call still auto-records while Discord sits in a channel.
        var pendingConfirmation: StartDecision?
        for holder in holders {
            guard let profile = MeetingAppRegistry.profile(for: holder.bundleID) else {
                return .start(holder: holder, debounce: nil)  // unknown app — default policy
            }
            if profile.requiresConfirmation {
                if pendingConfirmation == nil {
                    pendingConfirmation = .confirm(
                        holder: holder, debounce: profile.startDebounceOverride
                    )
                }
                continue
            }
            return .start(holder: holder, debounce: profile.startDebounceOverride)
        }
        return pendingConfirmation ?? .none
    }

    /// Is the app this recording is bound to still on the microphone? Other
    /// holders don't count either way: Discord idling in a channel must not
    /// keep a finished Teams recording alive, and a call switching
    /// microphones is still the same call.
    private func handleTracking(holders: [MicHolder]) {
        guard let tracked = trackedHolder else { return }
        inUseSince = nil
        if let live = holders.first(where: { Self.isSameApp($0, tracked) }) {
            clearSince = nil
            if let device = live.inputDevice, device != tracked.inputDevice {
                let from = tracked.inputDevice?.name ?? "no reported microphone"
                LogManager.send(
                    "\(Self.describe(tracked, withDevice: false)) moved from \(from) to \(device.name) — still the same call",
                    category: .audio
                )
                trackedHolder = live
                onSourceDeviceChanged?(live)
            }
            return
        }
        if clearSince == nil { clearSince = now() }
        guard let since = clearSince else { return }
        if now().timeIntervalSince(since) >= stopDebounce {
            LogManager.send(
                "Auto-detected meeting end (\(Self.describe(tracked, withDevice: false)) off the microphone for \(Int(stopDebounce))s)",
                category: .audio
            )
            onStopRequested?()
        }
    }

    private static func describe(_ holder: MicHolder, withDevice: Bool = true) -> String {
        let who = holder.appName ?? holder.bundleID ?? "pid \(holder.pid)"
        guard withDevice, let device = holder.inputDevice else { return who }
        return "\(who) on \(device.name)"
    }

    private func queryMicInUse() -> Bool {
        !snapshotHolders().isEmpty
    }

    /// Every process *other than us* with an active input IOProc, along with
    /// whether it is also running output IO. Uses Core Audio HAL's per-process
    /// APIs (macOS 14.4+), which see HAL-direct clients like Microsoft Teams
    /// and Zoom that `AVCaptureDevice.isInUseByAnotherApplication` misses
    /// entirely.
    ///
    /// Polled rather than observed: property listeners for the `IsRunning*`
    /// selectors are documented as unreliable, and we already tick on a timer.
    ///
    /// Safe to call when disabled — `RecordingViewModel` uses it for a
    /// one-shot read when a recording is started manually.
    /// Off-main wrapper for the poll.
    ///
    /// The CoreAudio calls below are synchronous mach round-trips to
    /// coreaudiod — one to list process objects, then two per process — and
    /// the very first of them makes the HAL check out an instance, load its
    /// plug-ins and enumerate every device. Run on the main thread that is a
    /// beachball at launch, which is exactly where it showed up: the sample
    /// caught `tick()` inside `HALSystem::InitializeDevices()`.
    nonisolated static func holdersOffMainThread() async -> [MicHolder] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: snapshotHoldersSynchronously())
            }
        }
    }

    /// Synchronous read. Only for the one-shot check when a recording is
    /// started by hand — never on a timer, and never during launch.
    func snapshotHolders() -> [MicHolder] {
        let holders = Self.snapshotHoldersSynchronously()
        logHolderChange(holders)
        return holders
    }

    nonisolated static func snapshotHoldersSynchronously() -> [MicHolder] {
        let myPID = getpid()
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize, &processObjects
        ) == noErr else {
            return []
        }

        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Input-scoped: the global scope answers with nothing, and the output
        // scope lists the speakers. Verified 2026-09-08 against a live Teams
        // call, which reported "Yeti Stereo Microphone" here.
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var holders: [MicHolder] = []
        for processObject in processObjects {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(
                processObject, &pidAddress, 0, nil, &pidSize, &pid
            ) == noErr, pid != myPID else { continue }

            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                processObject, &inputAddress, 0, nil, &runningSize, &running
            ) == noErr, running == 1 else { continue }

            // Deliberately not reading kAudioProcessPropertyIsRunningOutput:
            // it is continuously true for an app sitting in an empty voice
            // channel (measured 2026-08-03), so it cannot tell a live call
            // from an idle one and is not worth a property read per poll.
            let app = NSRunningApplication(processIdentifier: pid)
            holders.append(MicHolder(
                pid: pid,
                bundleID: app?.bundleIdentifier,
                appName: MeetingAppRegistry.displayName(
                    for: app?.bundleIdentifier,
                    fallback: app?.localizedName
                ),
                inputDevice: Self.inputDevice(of: processObject, address: &devicesAddress)
            ))
        }

        return holders
    }

    /// The first recordable microphone a process object has open, if any.
    nonisolated private static func inputDevice(
        of processObject: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> InputDevice? {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(processObject, &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }
        for device in devices where AudioDeviceInfo.isRecordableInput(device) {
            guard let uid = AudioDeviceInfo.uid(of: device), let name = AudioDeviceInfo.name(of: device) else { continue }
            return InputDevice(uid: uid, name: name)
        }
        return nil
    }

    /// Logs only on transitions — the poll runs every 5s and would otherwise
    /// flood the activity log for the entire length of a call.
    private func logHolderChange(_ holders: [MicHolder]) {
        guard holders != lastLoggedHolders else { return }
        lastLoggedHolders = holders
        let identity = holders
            .map { holder in
                let who = holder.bundleID ?? "pid \(holder.pid)"
                return holder.inputDevice.map { "\(who) on \($0.name)" } ?? who
            }
            .joined(separator: ", ")
        if holders.isEmpty {
            LogManager.send("Meeting detector: no other app holding the mic", category: .audio)
        } else {
            LogManager.send("Meeting detector sees input IO from \(identity)", category: .audio)
        }
    }
}

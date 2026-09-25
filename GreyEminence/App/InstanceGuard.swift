import AppKit

/// Keeps the released build and a development build off the same data at
/// the same time. They share a bundle identifier and a container, so both
/// auto-detect every call and record it twice — and a copy launching
/// mid-call would take the other's live recording for a crashed one and
/// close it off.
///
/// The development build wins: it's the one being tried out. A released
/// copy that opens while a development build runs brings that build
/// forward and quits. A development build that opens while a released
/// copy runs offers to quit the released one — unless it's recording.
@MainActor
enum InstanceGuard {
    /// Info.plist key holding `$(CONFIGURATION)` — "Debug" or "Release".
    static let configurationKey = "GEBuildConfiguration"

    enum Build: Equatable { case development, released }

    enum Action: Equatable {
        case proceed
        /// A released copy that should give way to a development build.
        case yieldToDevelopment
        /// A development build finding a released copy running.
        case offerToQuitReleased(isRecording: Bool)
    }

    /// Pure decision (unit-tested). `others` are the other running copies.
    static func decide(me: Build, others: [Build], recording: Bool) -> Action {
        switch me {
        case .released where others.contains(.development):
            .yieldToDevelopment
        case .development where others.contains(.released):
            .offerToQuitReleased(isRecording: recording)
        default:
            .proceed
        }
    }

    static func build(of bundle: Bundle?) -> Build {
        (bundle?.object(forInfoDictionaryKey: configurationKey) as? String) == "Debug" ? .development : .released
    }

    /// Call before any window or launch-time recovery runs.
    static func check() {
        // The test host is this app too; a dialog would stall the run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let me = build(of: .main)
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        let builds = others.map { app in (app, build(of: app.bundleURL.flatMap(Bundle.init(url:)))) }
        // This copy hasn't started recording, so a lock on disk is the
        // other copy's call in progress.
        let recording = !RecordingLockFile.scanAll().isEmpty

        switch decide(me: me, others: builds.map(\.1), recording: recording) {
        case .proceed:
            return

        case .yieldToDevelopment:
            LogManager.send("Released copy launched while a development build runs — closing", category: .general)
            let alert = NSAlert()
            alert.messageText = "The development build of Grey Eminence is running"
            alert.informativeText = "Both copies would record every call, so this one will close and the development build will come forward."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            builds.first { $0.1 == .development }?.0.activate()
            exit(0)

        case .offerToQuitReleased(let isRecording):
            let released = builds.filter { $0.1 == .released }.map(\.0)
            let alert = NSAlert()
            alert.messageText = "The released version of Grey Eminence is running"
            if isRecording {
                alert.informativeText = "It's recording a call. Quit this copy, and open it again once the call has ended."
                alert.addButton(withTitle: "Quit This Copy")
            } else {
                alert.informativeText = "Both copies would record every call. Quit the released version to use this one?"
                alert.addButton(withTitle: "Quit Released Version")
                alert.addButton(withTitle: "Quit This Copy")
            }
            let response = alert.runModal()
            if !isRecording, response == .alertFirstButtonReturn {
                LogManager.send("Development build launched — quitting the released copy", category: .general)
                released.forEach { $0.terminate() }
                return
            }
            released.first?.activate()
            exit(0)
        }
    }
}

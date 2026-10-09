import CoreGraphics
import Foundation

/// How to recognize the "shared content" window for one conferencing app.
///
/// Each app signals a share differently: Teams pops the content into a window
/// whose title names the presenter, while Discord renders a stream inside the
/// main window until you pop it out or fullscreen it. Keeping the signals as
/// data means adapting to a UI change is an edit here, not a rewrite of the
/// scorer.
struct ShareAppProfile: Sendable, Equatable {
    /// Identity (bundle IDs, display name, helper matching) is owned by
    /// `MeetingAppRegistry`; this type only adds share-window recognition, so
    /// there is one place to add an app.
    let app: MeetingAppProfile
    var displayName: String { app.displayName }

    /// Lowercased substrings that mark a window as the shared content itself.
    let shareTitlePatterns: [String]

    /// Lowercased substrings that mark the app's own chrome — the chat/home
    /// window we must never auto-capture.
    let mainWindowPatterns: [String]

    /// Lowercased *whole* titles that mark the app's chrome.
    ///
    /// Substring matching cannot express Zoom's naming: its meeting window is
    /// titled exactly "Zoom", so the substring "zoom" would also swallow every
    /// pop-out title the app could possibly use. Exact titles let a profile say
    /// "this window and no other".
    var mainWindowExactTitles: [String] = []

    /// Lowercased phrases on the placeholder screen left behind when the
    /// presenter stops sharing.
    let shareEndedPhrases: [String]

    /// This app puts shared content in a *second* window, so a second window
    /// that isn't the main one is very likely the share.
    var secondaryWindowIsShare: Bool = false

    /// This app is commonly fullscreened to view a share, so a window filling
    /// a whole display is likely the share.
    var fullscreenIsShare: Bool = false

    /// A window of this app with an unfamiliar title — not its chrome, not a
    /// known share title — is probably the share. Only sound while the app
    /// brands every chrome window; Teams stopped doing that (2026-10-09).
    var unbrandedTitleIsShare: Bool = true

    /// Shown in the picker and settings to explain how to get a clean capture.
    let popOutHint: String
}

/// Registry of per-app screen-share recognition profiles.
enum ShareAppProfiles {

    /// Teams — unchanged from the original Teams-only implementation. The
    /// pop-out content window carries the presenter's name ("Alice is
    /// presenting"), and the main window is branded "| Microsoft Teams".
    static let teams = ShareAppProfile(
        app: MeetingAppRegistry.teams,
        shareTitlePatterns: [
            "is presenting",
            "is sharing",
            "screen shar",       // "screen share" / "screen sharing"
            "shared content",
            "content shared",
        ],
        mainWindowPatterns: [
            "| microsoft teams",
            "microsoft teams",
            "chat |",
            "calendar |",
            "activity |",
        ],
        mainWindowExactTitles: ["chat", "calendar", "activity", "calls", "teams", "onedrive", "apps"],
        shareEndedPhrases: ScreenFrameTriage.shareEndedPhrases,
        // Since a Teams update on 2026-10-09 its windows are no longer
        // suffixed "| Microsoft Teams": the meeting window is titled with
        // just the meeting's name, so an unfamiliar title is no longer a
        // share. Only the share titles above auto-capture; the pop-out has
        // always carried one ("Shared content | …").
        unbrandedTitleIsShare: false,
        popOutHint: "Pop out the shared content in Teams for the cleanest capture."
    )

    /// Discord — a Go Live stream renders *inside* the main window alongside
    /// the channel sidebar, member list, and chat, all of which churn
    /// constantly and would dominate change detection. So we only auto-capture
    /// the popped-out or fullscreened stream, which is chrome-free.
    ///
    /// The title patterns are a starting guess: Discord's pop-out title is
    /// not documented and varies by what is being streamed. Every candidate's
    /// title is logged under the `screen` category, so the first real stream
    /// tells us what to put here. Until then the secondary-window and
    /// fullscreen rules carry the auto-detection.
    static let discord = ShareAppProfile(
        app: MeetingAppRegistry.discord,
        shareTitlePatterns: [
            "stream",
            "screen share",
            "screenshare",
            "is live",
            "go live",
        ],
        mainWindowPatterns: [
            "discord",
        ],
        shareEndedPhrases: [
            "the stream has ended",
            "stream ended",
            "no one is streaming",
            "screen share ended",
            "nobody is streaming",
        ],
        secondaryWindowIsShare: true,
        fullscreenIsShare: true,
        popOutHint: "Pop out the stream in Discord, or fullscreen it, for the cleanest capture."
    )

    /// Zoom — the viewer sees a share inside the meeting window, and can pop
    /// the shared content into a window of its own (also what dual-monitor
    /// mode produces). That pop-out is the clean capture; the meeting window
    /// is a gallery of faces whenever nobody is sharing, so auto-capturing it
    /// would burn frame budget on video thumbnails.
    ///
    /// Zoom pins its auxiliary windows well above the normal window level
    /// (the floating video window measured at layer 26 on 2026-08-12), which
    /// is why `candidates(from:)` no longer requires layer 0.
    ///
    /// As with Discord, the title patterns are informed guesses — taken from
    /// Zoom's own localized strings ("You are viewing %@'s screen",
    /// "%@'s screen share") rather than an observed pop-out. Every candidate
    /// is logged with its title and layer under the `screen` category, so the
    /// first real pop-out tells us what belongs here; until then the
    /// secondary-window and fullscreen rules carry auto-detection.
    static let zoom = ShareAppProfile(
        app: MeetingAppRegistry.zoom,
        shareTitlePatterns: [
            "'s screen",         // "Alice's screen" / "Alice's screen share"
            "’s screen",         // Zoom uses a typographic apostrophe in places
            "screen share",
            "is sharing",
            "shared screen",
        ],
        mainWindowPatterns: [
            "zoom workplace",
            "floating video window",
            "zoom group chat",
            "advanced diagnostics",
        ],
        mainWindowExactTitles: [
            "zoom",
            "zoom meeting",
            "login",
            "settings",
        ],
        shareEndedPhrases: [
            "screen sharing has stopped",
            "screen sharing stopped",
            "the shared window was closed",
            "stopped sharing",
        ],
        secondaryWindowIsShare: true,
        fullscreenIsShare: true,
        popOutHint: "Pop the shared content out into its own window in Zoom for the cleanest capture."
    )

    static let all: [ShareAppProfile] = [teams, discord, zoom]

    /// Matched through the registry so helper processes resolve the same way
    /// they do for mic detection — an exact-match table here would silently
    /// miss `com.hnc.Discord.helper.Renderer`.
    static func profile(for bundleID: String) -> ShareAppProfile? {
        guard let app = MeetingAppRegistry.profile(for: bundleID) else { return nil }
        return all.first { $0.app == app }
    }

    /// Generic guidance for the settings pane, which is app-agnostic because
    /// it is read before any call is in progress.
    static var genericPopOutHint: String {
        let names = ListFormatter.localizedString(byJoining: all.map(\.displayName))
        return "Pop out the shared content in \(names) for the cleanest capture."
    }
}

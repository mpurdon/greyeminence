import SwiftUI

/// One curated, user-facing feature worth surfacing after an update. Drives
/// BOTH the What's New sheet (filtered by `version`) and the in-context "NEW"
/// badge (keyed by `id`). Keep this list SHORT and benefit-oriented — it's the
/// trailer, not the changelog. The exhaustive history lives in ChangelogView.
struct FeatureHighlight: Identifiable, Sendable {
    /// Stable key — also the badge-tracking id. Never reuse or rename once
    /// shipped, or a badge/seen-state will resurface or leak across features.
    let id: String
    /// MARKETING_VERSION this shipped in. The sheet shows highlights newer than
    /// the user's last-seen version.
    let version: String
    let title: String
    let summary: String
    let systemImage: String
    let tint: Color
    /// Where "Try it" takes the user. `nil` hides the button.
    let destination: SidebarDestination?
}

enum FeatureHighlightCatalog {
    /// Newest first. Add an entry when a release ships something worth a nudge;
    /// set its `version` to that release's MARKETING_VERSION.
    static let all: [FeatureHighlight] = [
        FeatureHighlight(
            id: "pinned-meetings-highlight",
            version: "0.47.0",
            title: "Pin the meetings you keep going back to",
            summary: "Right-click a meeting and choose Pin. It moves to a Pinned section at the top of the list and stays out of the archive however old it gets. Right-click a transcript line and Save Audio Clip\u{2026} writes that moment to an .m4a \u{2014} the same audio the play button plays, from the same track.",
            systemImage: "pin.fill",
            tint: .yellow,
            destination: nil
        ),
        FeatureHighlight(
            id: "speaker-separation",
            version: "0.32.0",
            title: "Transcripts tell people apart",
            summary: "Everyone but you used to show as a single \"Speaker\", however many were on the call — the accuracy pass that rewrites each transcript was labelling lines by which microphone they came from. Voices are now separated, and you can put a name to one from the bar above the transcript. Name someone once and Grey Eminence recognises their voice in later meetings on its own. Settings \u{2192} Audio can go back and separate older recordings too, while their audio is still around.",
            systemImage: "person.2.wave.2",
            tint: .orange,
            destination: .settings
        ),
        FeatureHighlight(
            id: "ask-better-search",
            version: "0.31.0",
            title: "Ask can find what you meant",
            summary: "Search can now run on a real embedding model through your own AWS account, so a question phrased nothing like the conversation still finds it — \"what couldn\u{2019}t we process because of cost\" matches \"there\u{2019}s no way we can turn this on\". Name someone and it narrows to meetings they were in or were mentioned in, instead of hunting for their name. Settings \u{2192} Ask, and Help \u{2192} Setting Up Ask walks through it.",
            systemImage: "sparkle.magnifyingglass",
            tint: .teal,
            destination: .settings
        ),
        FeatureHighlight(
            id: "ask-conversations",
            version: "0.31.0",
            title: "Ask is a conversation now",
            summary: "Ask keeps the thread: follow up, dig in, change your mind, and it carries the context — including a follow-up like \"what did she say about that?\", which it works out before searching. Name someone and it narrows to the meetings they were in rather than hunting for their name. The snippets behind every answer sit in the side panel, numbered to match the citations, so you can tap [3] and land on the moment it came from.",
            systemImage: "bubble.left.and.text.bubble.right",
            tint: .purple,
            destination: .ask
        ),
        FeatureHighlight(
            id: "discord-calls",
            version: "0.24.0",
            title: "Record Discord calls",
            summary: "Grey Eminence now recognizes Discord. Because Discord holds the mic the whole time you're in a voice channel, it asks before recording rather than starting on its own — answer from the menu bar without leaving the call. Popped-out or fullscreened streams get captured like any other shared screen.",
            systemImage: "phone.badge.waveform.fill",
            tint: .blue,
            destination: .settings
        ),
        FeatureHighlight(
            id: "meeting-prep-panel",
            version: "0.23.13",
            title: "Meeting Prep, beside the transcript",
            summary: "While recording a recurring meeting, flip the side panel to Prep to see carried-over tasks, open questions, and prior topics — your talking points, right where you need them.",
            systemImage: "doc.text.magnifyingglass",
            tint: .indigo,
            destination: .recording
        ),
        FeatureHighlight(
            id: "screen-capture",
            version: "0.23.13",
            title: "Screen-share capture",
            summary: "Grey Eminence now watches for shared screens during a meeting and folds what it sees into the notes and summary — works with Teams, Zoom, Meet, anything.",
            systemImage: "rectangle.inset.filled.and.person.filled",
            tint: .cyan,
            destination: .settings
        ),
    ]

    /// The running app's marketing version (e.g. "0.23.13").
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Cap on how many highlights any one presentation shows — a user who
    /// skipped many releases gets the headline set, not an endless scroll (the
    /// rest stay in the changelog).
    private static let defaultLimit = 4

    /// Highlights newer than `lastSeenVersion`, newest first, capped.
    static func pending(since lastSeenVersion: String, limit: Int = defaultLimit) -> [FeatureHighlight] {
        let newer = all.filter { SemVer.compare($0.version, lastSeenVersion) == .orderedDescending }
        return Array(newer.prefix(limit))
    }

    /// The newest highlights regardless of what the user has already seen — for
    /// Help → What's New, where `pending` would be empty (the post-update sheet
    /// records the current version on dismissal, so nothing is ever pending once
    /// it has been shown). Every shipped highlight postdates "0.0.0", so this is
    /// `pending` with the floor removed — one selection policy, not two.
    static func headline(limit: Int = defaultLimit) -> [FeatureHighlight] {
        pending(since: "0.0.0", limit: limit)
    }
}

/// Numeric, dot-separated version comparison ("0.23.13" vs "0.9.2"). Leading
/// non-digits (a "v" prefix) and trailing build/pre-release tags are ignored;
/// missing components read as 0, so "0.24" == "0.24.0".
enum SemVer {
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let ac = parts(a), bc = parts(b)
        for i in 0..<Swift.max(ac.count, bc.count) {
            let x = i < ac.count ? ac[i] : 0
            let y = i < bc.count ? bc[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func parts(_ v: String) -> [Int] {
        v.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }
}

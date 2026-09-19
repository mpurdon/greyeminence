import SwiftUI

/// Which settings pane is showing. Shared so a pane can send the user to
/// another one — "the model is chosen in AI settings" is only helpful if it
/// is also a link.
@Observable
@MainActor
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var pane: SettingsPane = .general
    /// Tab within the AI pane. Set alongside `pane` by links that know
    /// which one they mean ("the model is chosen in AI → Search").
    var aiTab: AISettingsTab = .account

    private init() {}

    func showAI(_ tab: AISettingsTab) {
        aiTab = tab
        pane = .ai
    }
}

/// The AI pane is four things that used to scroll past each other: the
/// account that pays, and the three features that spend. One tab each.
enum AISettingsTab: String, CaseIterable, Identifiable {
    case account
    case meetingAnalysis
    case screenFrames
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: "Account"
        case .meetingAnalysis: "Meeting Analysis"
        case .screenFrames: "Screen Frames"
        case .search: "Search"
        }
    }
}

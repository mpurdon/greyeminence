import SwiftUI

/// Which settings pane is showing. Shared so a pane can send the user to
/// another one — "the model is chosen in AI settings" is only helpful if it
/// is also a link.
@Observable
@MainActor
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var pane: SettingsPane = .general

    private init() {}
}

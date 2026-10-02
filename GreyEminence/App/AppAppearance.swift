import AppKit

/// Light, dark, or whatever macOS is set to. Applied to the whole app —
/// every window, sheet, popover and menu — through `NSApp.appearance`, so
/// nothing has to opt in. Exports stay light: they're for paper.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor
    static func apply(_ rawValue: String) {
        let appearance = AppAppearance(rawValue: rawValue) ?? .system
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

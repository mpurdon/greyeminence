import SwiftUI
import Sparkle

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case audio
    case ai
    case vocabulary
    case obsidian

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .audio: "Audio"
        case .ai: "AI"
        case .vocabulary: "Vocabulary"
        case .obsidian: "Obsidian"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .audio: "mic"
        case .ai: "brain"
        case .vocabulary: "textformat.abc"
        case .obsidian: "doc.text"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: .gray
        case .audio: .blue
        case .ai: .purple
        case .vocabulary: .teal
        case .obsidian: .indigo
        }
    }

    var iconView: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(iconColor.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct SettingsView: View {
    var updater: SPUUpdater?
    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    pane.iconView
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(190)
        } detail: {
            switch selectedPane {
            case .general:
                GeneralSettingsView(updater: updater)
            case .audio:
                AudioSettingsView()
            case .ai:
                APIKeySettingsView()
            case .vocabulary:
                VocabularySettingsView()
            case .obsidian:
                ObsidianSettingsView()
            }
        }
        .modifier(SettingsToolbarModifier())
    }
}

private struct SettingsToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

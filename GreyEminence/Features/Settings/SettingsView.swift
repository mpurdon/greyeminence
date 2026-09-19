import SwiftUI
import Sparkle

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case audio
    case screenShare
    case ai
    case aiUsage
    case ask
    case vocabulary
    case organization
    case calendar
    case interview
    case obsidian
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .audio: "Audio"
        case .screenShare: "Screen Share"
        case .ai: "AI"
        case .aiUsage: "AI Usage"
        case .ask: "Ask"
        case .vocabulary: "Vocabulary"
        case .organization: "Organization"
        case .calendar: "Calendar"
        case .interview: "Interview"
        case .obsidian: "Obsidian"
        case .developer: "Developer"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .audio: "mic"
        case .screenShare: "rectangle.dashed.badge.record"
        case .ai: "brain"
        case .aiUsage: "chart.bar"
        case .ask: "sparkles.square.filled.on.square"
        case .vocabulary: "textformat.abc"
        case .organization: "building.2"
        case .calendar: "calendar"
        case .interview: "person.badge.shield.checkmark"
        case .obsidian: "doc.text"
        case .developer: "hammer"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: .gray
        case .audio: .blue
        case .screenShare: .mint
        case .ai: .purple
        case .aiUsage: .yellow
        case .ask: .pink
        case .vocabulary: .teal
        case .organization: .cyan
        case .calendar: .green
        case .interview: .orange
        case .obsidian: .indigo
        case .developer: .brown
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
    private var navigation = SettingsNavigation.shared
    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        // Manual HStack instead of a nested NavigationSplitView: macOS
        // auto-collapses inner split views in some layouts, which made
        // the pane list (including Developer) invisible until the user
        // happened to click the chevron. A fixed-width sidebar matches
        // the main-app pattern in ContentView and stays put.
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    pane.iconView
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Panes navigate through the shared object; the list selection
        // mirrors it both ways so a click and a "Change in AI settings"
        // link land in the same place.
        .onAppear { selectedPane = navigation.pane }
        .onChange(of: navigation.pane) { _, pane in selectedPane = pane }
        .onChange(of: selectedPane) { _, pane in navigation.pane = pane }
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedPane {
        case .general:
            GeneralSettingsView(updater: updater)
        case .audio:
            AudioSettingsView()
        case .screenShare:
            ScreenShareSettingsView()
        case .ai:
            APIKeySettingsView()
        case .aiUsage:
            AIUsageSettingsView()
        case .ask:
            AskSettingsView()
        case .vocabulary:
            VocabularySettingsView()
        case .organization:
            OrganizationSettingsView()
        case .calendar:
            CalendarSettingsView()
        case .interview:
            InterviewSettingsView()
        case .obsidian:
            ObsidianSettingsView()
        case .developer:
            DeveloperSettingsView()
        }
    }
}

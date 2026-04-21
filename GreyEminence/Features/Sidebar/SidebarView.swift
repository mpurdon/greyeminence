import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selection: SidebarDestination?
    @Binding var isExpanded: Bool
    @AppStorage("developerToolsEnabled") private var developerToolsEnabled = false
    @Query(filter: #Predicate<ActionItem> { !$0.isCompleted })
    private var pendingActions: [ActionItem]

    private let expandedWidth: CGFloat = 200
    private let collapsedWidth: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            toggleButton
                .padding(.top, 8)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 2) {
                    sidebarItem(.dashboard)
                    sidebarItem(.ask)

                    sectionHeader("Recording")
                    sidebarItem(.recording)

                    sectionHeader("Library")
                    sidebarItem(.meetings)
                    tasksItem
                    sidebarItem(.interviews)
                    sidebarItem(.people)
                    sidebarItem(.topicMap)
                    if developerToolsEnabled {
                        sidebarItem(.activityLog)
                    }
                }
                .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)

            settingsButton
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
        }
        .frame(width: isExpanded ? expandedWidth : collapsedWidth)
        .background(.background)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    // MARK: - Toggle

    private var toggleButton: some View {
        HStack {
            if isExpanded { Spacer() }
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            if !isExpanded { Spacer() }
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        if isExpanded && !title.isEmpty {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
        } else {
            Spacer()
                .frame(height: title.isEmpty ? 4 : 12)
        }
    }

    // MARK: - Sidebar Item

    private func sidebarItem(_ destination: SidebarDestination) -> some View {
        let isSelected = selection == destination

        return Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                destination.iconView

                if isExpanded {
                    Text(destination.rawValue)
                        .font(.body)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, isExpanded ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .background(
                isSelected
                    ? AnyShapeStyle(.selection)
                    : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tasks Item (with badge)

    private var tasksItem: some View {
        let destination = SidebarDestination.tasks
        let isSelected = selection == destination

        return Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    destination.iconView

                    if !isExpanded && !pendingActions.isEmpty {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 3, y: -3)
                    }
                }

                if isExpanded {
                    Text(destination.rawValue)
                        .font(.body)
                        .lineLimit(1)
                    Spacer()
                    if !pendingActions.isEmpty {
                        Text("\(pendingActions.count)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red.opacity(0.2), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, isExpanded ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .background(
                isSelected
                    ? AnyShapeStyle(.selection)
                    : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings Button (bottom)

    private var settingsButton: some View {
        VStack(spacing: 4) {
            Divider()
            sidebarItem(.settings)
        }
    }
}

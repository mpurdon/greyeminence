import SwiftUI
import SwiftData
import AppKit

struct InterviewHubView: View {
    @Environment(\.modelContext) private var modelContext
    var interviewViewModel: InterviewRecordingViewModel
    @Binding var showInspector: Bool
    @Binding var inspectorWidth: CGFloat?

    @State private var selectedInterview: Interview?
    @State private var activeTab: InterviewHubTab = .interviews

    enum InterviewHubTab: String, CaseIterable {
        case interviews = "Interviews"
        case setup = "New Interview"
        case candidates = "Candidates"
        case rubrics = "Rubrics"
    }

    var body: some View {
        if interviewViewModel.isInterviewActive {
            liveInterviewLayout
        } else {
            VStack(spacing: 0) {
                Picker("", selection: $activeTab) {
                    ForEach(InterviewHubTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch activeTab {
                case .interviews:
                    InterviewListView(selectedInterview: $selectedInterview, showInspector: $showInspector, inspectorWidth: $inspectorWidth)
                case .setup:
                    InterviewSetupView(interviewViewModel: interviewViewModel)
                case .candidates:
                    CandidateListView()
                case .rubrics:
                    RubricListView()
                }
            }
        }
    }

    // MARK: - Live Interview Layout

    private var liveInterviewLayout: some View {
        GeometryReader { geo in
            let defaultWidth = geo.size.width * 0.32
            let width = inspectorWidth ?? defaultWidth
            let clampedWidth = min(max(width, 220), geo.size.width * 0.50)

            VStack(spacing: 0) {
                // Shared header — full width, above both panels
                InterviewLiveHeader(
                    interviewViewModel: interviewViewModel,
                    modelContext: modelContext
                )

                Divider()

                // Content: main panel + right panel side by side
                HStack(spacing: 0) {
                    LiveInterviewIntelligenceView(interviewViewModel: interviewViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showInspector {
                        panelDragHandle(containerWidth: geo.size.width)
                        LiveInterviewView(interviewViewModel: interviewViewModel)
                            .frame(width: clampedWidth)
                    }
                }
            }
        }
    }

    private func panelDragHandle(containerWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newWidth = (inspectorWidth ?? containerWidth * 0.32) - value.translation.width
                        inspectorWidth = min(max(newWidth, 220), containerWidth * 0.50)
                    }
            )
            .overlay { Divider() }
    }
}

// MARK: - Shared Full-Width Header

private struct InterviewLiveHeader: View {
    var interviewViewModel: InterviewRecordingViewModel
    var modelContext: ModelContext

    var body: some View {
        HStack(spacing: 8) {
            // Left: candidate
            if let candidate = interviewViewModel.interview?.candidate {
                Text(candidate.initials)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(candidate.avatarColor.gradient, in: Circle())
                Text(candidate.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Center: phase timeline pills
            phaseTimeline

            Spacer(minLength: 4)

            // Right: quick actions
            Button {
                interviewViewModel.addBookmark(type: .bookmark)
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("b", modifiers: .command)
            .help("Bookmark (⌘B)")

            Button {
                interviewViewModel.addBookmark(type: .redFlag)
            } label: {
                Image(systemName: "flag.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Red Flag (⌘⇧F)")

            AIActivityIndicator(state: interviewViewModel.rubricAnalysisState)

            Button {
                interviewViewModel.stopInterview(in: modelContext)
            } label: {
                Label("End Interview", systemImage: "stop.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Compact Pill Timeline

    private var phaseTimeline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                phasePill("Intro", id: InterviewRecordingViewModel.introID, grade: nil)

                ForEach(interviewViewModel.sectionScores.sorted(by: { $0.sortOrder < $1.sortOrder })) { score in
                    phasePill(score.rubricSectionTitle, id: score.rubricSectionID, grade: score.effectiveLetterGrade)
                }

                phasePill("Conclusion", id: InterviewRecordingViewModel.conclusionID, grade: nil)
            }
        }
    }

    private func phasePill(_ title: String, id: UUID, grade: LetterGrade?) -> some View {
        let isActive = interviewViewModel.activePhaseID == id
        return Button {
            interviewViewModel.setActivePhase(id)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: isActive ? .bold : .medium))
                    .lineLimit(1)
                if let grade {
                    Text(grade.label)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(bellCurveColor(for: grade.gradePoints / 4.0), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isActive ? Color.cyan.opacity(0.15) : Color.secondary.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(isActive ? Color.cyan : Color.secondary.opacity(0.15), lineWidth: isActive ? 1.5 : 0.5))
            .foregroundStyle(isActive ? .cyan : .secondary)
        }
        .buttonStyle(.plain)
    }
}

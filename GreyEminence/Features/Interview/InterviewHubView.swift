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

}

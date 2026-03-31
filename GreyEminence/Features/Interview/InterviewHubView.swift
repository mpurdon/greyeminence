import SwiftUI
import SwiftData

struct InterviewHubView: View {
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
            // Live interview: rubric/scoring is primary, transcript is inspector
            GeometryReader { geo in
                let defaultWidth = geo.size.width * 0.35
                let width = inspectorWidth ?? defaultWidth
                let clampedWidth = min(max(width, 250), geo.size.width * 0.5)

                HStack(spacing: 0) {
                    // Primary: rubric scoring + intelligence
                    LiveInterviewIntelligenceView(interviewViewModel: interviewViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector {
                        Divider()
                        // Inspector: transcript + controls
                        LiveInterviewView(interviewViewModel: interviewViewModel)
                            .frame(width: clampedWidth)
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                // Tab bar
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
}

import SwiftUI
import SwiftData

struct InterviewHubView: View {
    @Binding var showInspector: Bool
    @Binding var inspectorWidth: CGFloat?

    @State private var selectedInterview: Interview?
    @State private var activeTab: InterviewHubTab = .interviews

    enum InterviewHubTab: String, CaseIterable {
        case interviews = "Interviews"
        case candidates = "Candidates"
        case rubrics = "Rubrics"
    }

    var body: some View {
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
            case .candidates:
                CandidateListView()
            case .rubrics:
                RubricListView()
            }
        }
    }
}

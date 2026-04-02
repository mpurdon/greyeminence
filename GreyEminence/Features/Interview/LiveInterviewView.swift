import SwiftUI
import SwiftData

/// Right-panel during a live interview. Toggles between Transcript and Notes.
/// Collapsible and resizable via the parent InterviewHubView.
struct LiveInterviewView: View {
    @Environment(\.modelContext) private var modelContext
    var interviewViewModel: InterviewRecordingViewModel
    @State private var activeTab: PanelTab = .transcript

    enum PanelTab: String, CaseIterable {
        case transcript = "Transcript"
        case notes = "Notes"
    }

    private var recordingVM: RecordingViewModel {
        interviewViewModel.recordingViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: tab picker + recording info
            HStack(spacing: 6) {
                Picker("", selection: $activeTab) {
                    ForEach(PanelTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Spacer(minLength: 4)

                if activeTab == .transcript {
                    Image(systemName: "waveform")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("\(recordingVM.segments.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                RecordingToolbar(viewModel: recordingVM, modelContext: modelContext)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.bar)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Content
            switch activeTab {
            case .transcript:
                transcriptContent
            case .notes:
                notesContent
            }

            Divider()

            // Bottom: bookmark buttons (always visible)
            HStack(spacing: 8) {
                Button {
                    interviewViewModel.addBookmark(type: .bookmark)
                } label: {
                    Label("Bookmark", systemImage: "bookmark.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button {
                    interviewViewModel.addBookmark(type: .redFlag)
                } label: {
                    Label("Red Flag", systemImage: "flag.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Spacer()

                Text(recordingVM.formattedTime)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Transcript Tab

    private var transcriptContent: some View {
        VStack(spacing: 0) {
            LiveTranscriptView(
                segments: recordingVM.segments,
                segmentConfidence: recordingVM.segmentConfidence
            )

            Divider()

            NoteInputBar(viewModel: recordingVM)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
    }

    // MARK: - Notes Tab

    private var notesContent: some View {
        ScrollView {
            InterviewNotesTable(interviewViewModel: interviewViewModel)
                .padding(8)
        }
    }
}

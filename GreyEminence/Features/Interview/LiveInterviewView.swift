import SwiftUI
import SwiftData

/// Right-panel transcript view during a live interview.
/// Compact — shows transcript, note input, and bookmark buttons.
struct LiveInterviewView: View {
    @Environment(\.modelContext) private var modelContext
    var interviewViewModel: InterviewRecordingViewModel

    private var recordingVM: RecordingViewModel {
        interviewViewModel.recordingViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Compact header
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Transcript")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(recordingVM.segments.count)")
                    .font(.caption2)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.tertiary)
                RecordingToolbar(viewModel: recordingVM, modelContext: modelContext)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Live transcript
            LiveTranscriptView(
                segments: recordingVM.segments,
                segmentConfidence: recordingVM.segmentConfidence
            )

            Divider()

            // Bottom bar with note input and quick actions
            HStack(spacing: 8) {
                NoteInputBar(viewModel: recordingVM)
                    .frame(maxWidth: .infinity)

                Button {
                    interviewViewModel.addBookmark(type: .bookmark)
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Bookmark this moment")

                Button {
                    interviewViewModel.addBookmark(type: .redFlag)
                } label: {
                    Image(systemName: "flag.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Flag as red flag")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

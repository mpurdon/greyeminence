import SwiftUI
import SwiftData

struct LiveInterviewView: View {
    @Environment(\.modelContext) private var modelContext
    var interviewViewModel: InterviewRecordingViewModel

    private var recordingVM: RecordingViewModel {
        interviewViewModel.recordingViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Interview header bar
            interviewHeader

            Divider()

            // Live transcript
            LiveTranscriptView(
                segments: recordingVM.segments,
                segmentConfidence: recordingVM.segmentConfidence
            )

            Divider()

            // Bottom bar with note input and quick actions
            HStack(spacing: 12) {
                NoteInputBar(viewModel: recordingVM)
                    .frame(maxWidth: .infinity)

                // Quick action buttons
                Button {
                    interviewViewModel.addBookmark(type: .bookmark)
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .help("Bookmark this moment")

                Button {
                    interviewViewModel.addBookmark(type: .redFlag)
                } label: {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .help("Flag as red flag")
            }
            .padding(.trailing, 12)
        }
    }

    private var interviewHeader: some View {
        HStack(spacing: 12) {
            // Candidate info
            if let candidate = interviewViewModel.interview?.candidate {
                Text(candidate.initials)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(candidate.avatarColor.gradient, in: Circle())
                Text(candidate.name)
                    .font(.headline)
            }

            Text("·")
                .foregroundStyle(.tertiary)

            // Active section picker
            Picker("", selection: Binding(
                get: { interviewViewModel.activeSectionID },
                set: { interviewViewModel.setActiveSection($0) }
            )) {
                Text("General Discussion").tag(nil as UUID?)
                ForEach(interviewViewModel.sectionScores.sorted(by: { $0.sortOrder < $1.sortOrder })) { score in
                    Text(score.rubricSectionTitle).tag(score.rubricSectionID as UUID?)
                }
            }
            .frame(maxWidth: 180)
            .controlSize(.small)
            .help("Current interview phase — tells AI which rubric section to focus on")

            Spacer()

            // Recording controls
            RecordingToolbar(viewModel: recordingVM, modelContext: modelContext)
                .overlay(alignment: .bottom) {
                    EmptyView() // Hide the default error overlay — we handle it ourselves
                }

            // Stop interview button
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
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

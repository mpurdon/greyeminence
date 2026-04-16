import SwiftUI
import SwiftData
import AppKit

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: RecordingViewModel
    /// When true, the live transcript fills the body. When false, the live
    /// intelligence view fills the body and the transcript is expected to live
    /// in a separate pane (e.g. the inspector).
    var showsTranscript: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            RecordingToolbar(viewModel: viewModel, modelContext: modelContext)

            Divider()

            if viewModel.state == .idle {
                idleState
            } else if showsTranscript {
                LiveTranscriptView(
                    segments: viewModel.segments,
                    segmentConfidence: viewModel.segmentConfidence
                )
            } else {
                LiveMeetingIntelligenceView(
                    summary: viewModel.streamingSummary,
                    actionItems: viewModel.actionItems,
                    followUpQuestions: viewModel.followUpQuestions,
                    topics: viewModel.topics,
                    aiActivityState: viewModel.aiActivityState
                )
            }

            if viewModel.state != .idle {
                Divider()
                NoteInputBar(viewModel: viewModel)
            }
        }
        .navigationTitle(viewModel.currentMeeting?.title ?? "New Recording")
        .task {
            await TranscriptionCoordinator.preloadModels()
        }
    }

    private var idleState: some View {
        VStack(spacing: 20) {
            Spacer()

            // Show detected calendar event
            if let event = viewModel.calendarService.currentEvent {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title ?? "Meeting")
                            .font(.headline)
                        Text(event.startDate.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            // Meeting prep view
            if let prepContext = viewModel.prepContext, !prepContext.isEmpty {
                MeetingPrepView(context: prepContext)
                    .frame(maxWidth: 500)
            }

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Ready to Record")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Click the record button to start capturing your meeting")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                viewModel.startRecording(in: modelContext)
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut("r", modifiers: .command)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .task {
            let calendarEnabled = UserDefaults.standard.bool(forKey: "calendarIntegration")
            if calendarEnabled {
                await viewModel.calendarService.requestAccess()
                viewModel.calendarService.refreshCurrentEvent()
                viewModel.refreshPrepContext(in: modelContext)
            }
        }
    }
}

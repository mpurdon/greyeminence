import SwiftUI
import SwiftData
import AppKit

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: RecordingViewModel

    var body: some View {
        VStack(spacing: 0) {
            RecordingToolbar(viewModel: viewModel, modelContext: modelContext)

            Divider()

            if viewModel.state == .idle {
                idleState
            } else {
                LiveTranscriptView(segments: viewModel.segments)
            }

            if viewModel.state != .idle {
                Divider()
                NoteInputBar(viewModel: viewModel)
            }
        }
        .navigationTitle(viewModel.currentMeeting?.title ?? "New Recording")
        .alert("Dictation Required", isPresented: $viewModel.showDictationAlert) {
            Button("Open Keyboard Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Transcription requires Dictation to be enabled.\n\nGo to System Settings > Keyboard > Dictation and turn it on.")
        }
    }

    private var idleState: some View {
        VStack(spacing: 20) {
            Spacer()
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
    }
}

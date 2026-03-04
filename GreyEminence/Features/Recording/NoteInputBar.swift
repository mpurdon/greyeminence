import SwiftUI

struct NoteInputBar: View {
    @Bindable var viewModel: RecordingViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "note.text")
                .foregroundStyle(.secondary)

            TextField("Add a note...", text: $viewModel.manualNote)
                .textFieldStyle(.plain)
                .onSubmit {
                    viewModel.addManualNote()
                }

            Button {
                viewModel.addManualNote()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.manualNote.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

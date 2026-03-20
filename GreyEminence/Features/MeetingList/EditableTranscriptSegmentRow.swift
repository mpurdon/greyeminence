import SwiftUI
import SwiftData

struct EditableTranscriptSegmentRow: View {
    @Bindable var segment: TranscriptSegment
    let allSegments: [TranscriptSegment]

    @State private var isEditing = false
    @State private var editedText: String = ""
    @State private var showContactPicker = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timestamp
            Text(segment.formattedTimestamp)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)

            // Speaker badge
            SpeakerBadge(speaker: segment.speaker)
                .contextMenu {
                    Button("Change Speaker...") {
                        showContactPicker = true
                    }
                    Menu("Change All From This Speaker") {
                        Button("Change to Me") {
                            changeSpeakerForAll(to: .me)
                        }
                    }
                }
                .popover(isPresented: $showContactPicker) {
                    ContactPicker(excludedContacts: []) { contact in
                        changeSpeaker(to: .other(contact.name))
                        showContactPicker = false
                    }
                }

            // Edited indicator
            if segment.isEdited {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Edited")
            }

            // Text (editable on double-click)
            if isEditing {
                TextField("", text: $editedText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
            } else {
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) {
                        startEditing()
                    }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit Text") { startEditing() }
            if segment.isEdited {
                Button("Revert to Original") { revertToOriginal() }
            }
        }
    }

    private func startEditing() {
        editedText = segment.text
        isEditing = true
    }

    private func commitEdit() {
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != segment.text else {
            isEditing = false
            return
        }

        if !segment.isEdited {
            segment.originalText = segment.text
            segment.originalSpeakerData = segment.speakerData
        }
        segment.text = trimmed
        segment.isEdited = true
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
    }

    private func revertToOriginal() {
        guard segment.isEdited else { return }
        if let originalText = segment.originalText {
            segment.text = originalText
        }
        if let originalSpeakerData = segment.originalSpeakerData {
            segment.speakerData = originalSpeakerData
        }
        segment.originalText = nil
        segment.originalSpeakerData = nil
        segment.isEdited = false
    }

    private func changeSpeaker(to newSpeaker: Speaker) {
        if !segment.isEdited {
            segment.originalText = segment.text
            segment.originalSpeakerData = segment.speakerData
        }
        segment.speaker = newSpeaker
        segment.isEdited = true
    }

    private func changeSpeakerForAll(to newSpeaker: Speaker) {
        let currentSpeaker = segment.speaker
        for seg in allSegments {
            if seg.speaker == currentSpeaker {
                if !seg.isEdited {
                    seg.originalText = seg.text
                    seg.originalSpeakerData = seg.speakerData
                }
                seg.speaker = newSpeaker
                seg.isEdited = true
            }
        }
    }
}

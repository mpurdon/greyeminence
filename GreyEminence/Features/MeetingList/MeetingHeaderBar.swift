import SwiftUI
import SwiftData

struct MeetingHeaderBar: View {
    @Bindable var meeting: Meeting
    @Environment(\.modelContext) private var modelContext
    @State private var isEditingTitle = false
    @State private var editedTitle: String = ""
    @State private var exportState: ExportState = .idle
    @State private var showTranscriptSavePanel = false

    private enum ExportState: Equatable {
        case idle, success, error(String)
    }

    private var editedCount: Int {
        meeting.segments.filter(\.isEdited).count
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if isEditingTitle {
                    TextField("Meeting title", text: $editedTitle, onCommit: {
                        meeting.title = editedTitle
                        isEditingTitle = false
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
                } else {
                    Text(meeting.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .onTapGesture(count: 2) {
                            editedTitle = meeting.title
                            isEditingTitle = true
                        }
                }

                HStack(spacing: 12) {
                    Label(meeting.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    Label(meeting.formattedDuration, systemImage: "clock")
                    Label("\(meeting.segments.count) segments", systemImage: "text.bubble")
                    if editedCount > 0 {
                        Label("\(editedCount) edited", systemImage: "pencil")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if meeting.status == .completed {
                    MeetingAttendeesRow(meeting: meeting)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    do {
                        _ = try ObsidianExportService.export(meeting: meeting)
                        PersistenceGate.save(modelContext, site: "MeetingDetailView.obsidianExport", meetingID: meeting.id)
                        exportState = .success
                    } catch {
                        exportState = .error(error.localizedDescription)
                    }
                } label: {
                    switch exportState {
                    case .idle:
                        Label("Sync to Obsidian", systemImage: "arrow.up.doc")
                    case .success:
                        Label("Synced to Obsidian", systemImage: "checkmark.circle.fill")
                    case .error:
                        Label("Sync Failed", systemImage: "exclamation.triangle.fill")
                    }
                }
                .disabled(UserDefaults.standard.string(forKey: "obsidianVaultPath")?.isEmpty != false)
                .keyboardShortcut("e", modifiers: .command)
                .help(exportHelpText)

                Button {
                    showTranscriptSavePanel = true
                } label: {
                    Label("Save Transcript", systemImage: "doc.badge.arrow.up")
                }
                .help("Save transcript as a file for rubric testing")

                statusBadge
            }
        }
        .padding()
        .onChange(of: showTranscriptSavePanel) { _, show in
            guard show else { return }
            showTranscriptSavePanel = false
            DispatchQueue.main.async {
                saveTranscriptFile()
            }
        }
    }

    private var exportHelpText: String {
        switch exportState {
        case .idle: "Sync to Obsidian vault"
        case .success: "Successfully synced to Obsidian"
        case .error(let msg): msg
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (text, color) = switch meeting.status {
        case .recording: ("Recording", Color.red)
        case .paused: ("Paused", Color.orange)
        case .completed: ("Completed", Color.green)
        }

        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func saveTranscriptFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(meeting.title).getranscript.json"
        panel.title = "Save Transcript"
        panel.message = "Save this transcript for rubric testing"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = TranscriptFile.from(meeting: meeting)
            try file.write(to: url)
        } catch {
            LogManager.shared.log("Transcript save failed: \(error.localizedDescription)", category: .general, level: .error)
        }
    }
}

import SwiftUI
import SwiftData

struct MeetingHeaderBar: View {
    @Bindable var meeting: Meeting
    @Environment(\.modelContext) private var modelContext
    @Bindable private var reProcessingQueue: ReProcessingQueue = .shared
    @AppStorage("developerToolsEnabled") private var developerToolsEnabled = false
    @State private var isEditingTitle = false
    @State private var editedTitle: String = ""
    @State private var exportState: ExportState = .idle
    @State private var showTranscriptSavePanel = false
    @State private var didCopyID = false

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

                if developerToolsEnabled {
                    HStack(spacing: 4) {
                        Text(meeting.id.uuidString)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(meeting.id.uuidString, forType: .string)
                            didCopyID = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.2))
                                didCopyID = false
                            }
                        } label: {
                            Image(systemName: didCopyID ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(didCopyID ? Color.green : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy meeting ID")
                    }
                }

                HStack(spacing: 12) {
                    Label(meeting.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Label(meeting.formattedDuration, systemImage: "clock")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Label("\(meeting.segments.count) segments", systemImage: "text.bubble")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if editedCount > 0 {
                        Label("\(editedCount) edited", systemImage: "pencil")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if let raw = meeting.reProcessingState,
                       let state = ReProcessingState(rawValue: raw) {
                        HStack(spacing: 4) {
                            StatusPill(label: pillLabel(state: state), tint: state.tint)
                            Button {
                                reProcessingQueue.cancelCurrent(meetingID: meeting.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel re-transcription")
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    } else if meeting.transcriptionModel?.hasPrefix("whisperkit-large-v3") == true {
                        StatusPill(label: "large-v3", tint: .green)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if meeting.status == .completed {
                    MeetingAttendeesRow(meeting: meeting)
                }
            }

            Spacer()

            ViewThatFits(in: .horizontal) {
                actionButtons(iconOnly: false)
                actionButtons(iconOnly: true)
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
    private func actionButtons(iconOnly: Bool) -> some View {
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
                actionLabel(
                    title: exportTitle,
                    systemImage: exportIcon,
                    iconOnly: iconOnly
                )
            }
            .disabled(UserDefaults.standard.string(forKey: "obsidianVaultPath")?.isEmpty != false)
            .keyboardShortcut("e", modifiers: .command)
            .help(exportHelpText)

            Button {
                showTranscriptSavePanel = true
            } label: {
                actionLabel(title: "Save Transcript", systemImage: "doc.badge.arrow.up", iconOnly: iconOnly)
            }
            .help("Save transcript as a file for rubric testing")

            statusBadge
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func actionLabel(title: String, systemImage: String, iconOnly: Bool) -> some View {
        if iconOnly {
            Image(systemName: systemImage)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private var exportTitle: String {
        switch exportState {
        case .idle: "Sync to Obsidian"
        case .success: "Synced to Obsidian"
        case .error: "Sync Failed"
        }
    }

    private var exportIcon: String {
        switch exportState {
        case .idle: "arrow.up.doc"
        case .success: "checkmark.circle.fill"
        case .error: "exclamation.triangle.fill"
        }
    }

    private func pillLabel(state: ReProcessingState) -> String {
        if state == .transcribing,
           let job = reProcessingQueue.current,
           job.id == meeting.id,
           job.chunksTotal > 0 {
            return "\(state.label) \(job.chunksDone)/\(job.chunksTotal)"
        }
        return state.label
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

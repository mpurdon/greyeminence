import SwiftUI
import SwiftData

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    @Environment(\.modelContext) private var modelContext
    @State private var isEditing = false
    @State private var editedTitle: String = ""
    @State private var exportState: ExportState = .idle

    private enum ExportState: Equatable {
        case idle, success, error(String)
    }

    var sortedSegments: [TranscriptSegment] {
        meeting.segments.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if isEditing {
                        TextField("Meeting title", text: $editedTitle, onCommit: {
                            meeting.title = editedTitle
                            isEditing = false
                        })
                        .textFieldStyle(.roundedBorder)
                        .font(.title2)
                    } else {
                        Text(meeting.title)
                            .font(.title2)
                            .fontWeight(.bold)
                            .onTapGesture(count: 2) {
                                editedTitle = meeting.title
                                isEditing = true
                            }
                    }

                    HStack(spacing: 12) {
                        Label(meeting.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        Label(meeting.formattedDuration, systemImage: "clock")
                        Label("\(meeting.segments.count) segments", systemImage: "text.bubble")
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
                            try? modelContext.save()
                            exportState = .success
                        } catch {
                            exportState = .error(error.localizedDescription)
                        }
                    } label: {
                        switch exportState {
                        case .idle:
                            Label("Export", systemImage: "arrow.up.doc")
                        case .success:
                            Label("Exported", systemImage: "checkmark.circle.fill")
                        case .error:
                            Label("Export Failed", systemImage: "exclamation.triangle.fill")
                        }
                    }
                    .disabled(UserDefaults.standard.string(forKey: "obsidianVaultPath")?.isEmpty != false)
                    .keyboardShortcut("e", modifiers: .command)
                    .help(exportHelpText)

                    statusBadge
                }
            }
            .padding()

            Divider()

            // Transcript
            if sortedSegments.isEmpty {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "text.bubble",
                    description: Text("This meeting has no transcript segments")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedSegments) { segment in
                            TranscriptSegmentRow(segment: segment)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var exportHelpText: String {
        switch exportState {
        case .idle: "Export to Obsidian vault"
        case .success: "Successfully exported"
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
}

import SwiftUI
import SwiftData

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    @Environment(\.modelContext) private var modelContext
    @State private var isEditingTitle = false
    @State private var editedTitle: String = ""
    @State private var exportState: ExportState = .idle
    @State private var selectedSegmentIDs: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showBulkDeleteConfirmation = false
    @State private var showBulkSpeakerPicker = false
    @State private var showBulkSpeakerRename = false
    @State private var bulkSpeakerName: String = ""

    private enum ExportState: Equatable {
        case idle, success, error(String)
    }

    var sortedSegments: [TranscriptSegment] {
        meeting.segments.sorted { $0.startTime < $1.startTime }
    }

    private var editedCount: Int {
        meeting.segments.filter(\.isEdited).count
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            // Series link
            if meeting.seriesID != nil, let seriesTitle = meeting.seriesTitle {
                SeriesSectionView(meeting: meeting, seriesTitle: seriesTitle)
                    .padding(.horizontal)
                Divider()
            }

            // Editing toolbar (completed meetings only)
            if meeting.status == .completed && !sortedSegments.isEmpty {
                transcriptToolbar
                Divider()
            }

            // Transcript
            if sortedSegments.isEmpty {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "text.bubble",
                    description: Text("This meeting has no transcript segments")
                )
            } else {
                transcriptList
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .confirmationDialog(
            "Delete \(selectedSegmentIDs.count) segment\(selectedSegmentIDs.count == 1 ? "" : "s")?",
            isPresented: $showBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteSelectedSegments()
            }
        } message: {
            Text("This cannot be undone.")
        }
        .popover(isPresented: $showBulkSpeakerPicker) {
            ContactPicker(excludedContacts: []) { contact in
                reassignSelectedSegments(to: .other(contact.name))
                showBulkSpeakerPicker = false
            }
        }
        .popover(isPresented: $showBulkSpeakerRename) {
            VStack(spacing: 8) {
                Text("Rename Speaker")
                    .font(.headline)
                TextField("Speaker name", text: $bulkSpeakerName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let name = bulkSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        let speaker: Speaker = name.lowercased() == "me" ? .me : .other(name)
                        reassignSelectedSegments(to: speaker)
                        showBulkSpeakerRename = false
                    }
                HStack {
                    Button("Cancel") { showBulkSpeakerRename = false }
                    Spacer()
                    Button("Apply") {
                        let name = bulkSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        let speaker: Speaker = name.lowercased() == "me" ? .me : .other(name)
                        reassignSelectedSegments(to: speaker)
                        showBulkSpeakerRename = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding()
            .frame(width: 280)
        }
    }

    // MARK: - Header

    private var headerView: some View {
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
    }

    // MARK: - Transcript Toolbar

    private var transcriptToolbar: some View {
        HStack(spacing: 12) {
            // Selection mode toggle
            Button {
                isSelectionMode.toggle()
                if !isSelectionMode {
                    selectedSegmentIDs.removeAll()
                }
            } label: {
                Label(
                    isSelectionMode ? "Done" : "Select",
                    systemImage: isSelectionMode ? "checkmark.circle" : "checklist"
                )
            }
            .controlSize(.small)

            if isSelectionMode {
                // Select all / none
                Button(selectedSegmentIDs.count == sortedSegments.count ? "Select None" : "Select All") {
                    if selectedSegmentIDs.count == sortedSegments.count {
                        selectedSegmentIDs.removeAll()
                    } else {
                        selectedSegmentIDs = Set(sortedSegments.map(\.id))
                    }
                }
                .controlSize(.small)

                if !selectedSegmentIDs.isEmpty {
                    Divider()
                        .frame(height: 16)

                    Text("\(selectedSegmentIDs.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Bulk reassign speaker
                    Menu {
                        Button("Choose Contact...") {
                            showBulkSpeakerPicker = true
                        }
                        Button("Type Name...") {
                            bulkSpeakerName = ""
                            showBulkSpeakerRename = true
                        }
                        Divider()
                        Button("Set as Me") {
                            reassignSelectedSegments(to: .me)
                        }
                    } label: {
                        Label("Assign Speaker", systemImage: "person")
                    }
                    .controlSize(.small)

                    // Bulk delete
                    Button(role: .destructive) {
                        showBulkDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }

            Spacer()

            // Revert all edits
            if editedCount > 0 {
                Button("Revert All Edits") {
                    revertAllEdits()
                }
                .controlSize(.small)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(sortedSegments) { segment in
                    if meeting.status == .completed {
                        EditableTranscriptSegmentRow(
                            segment: segment,
                            allSegments: sortedSegments,
                            isSelected: selectedSegmentIDs.contains(segment.id),
                            onDelete: { deleteSegment(segment) },
                            onMergeWithNext: { mergeSegmentWithNext(segment) },
                            onSplit: { before, after in splitSegment(segment, before: before, after: after) },
                            onToggleSelection: isSelectionMode ? {
                                toggleSelection(segment)
                            } : nil
                        )
                    } else {
                        TranscriptSegmentRow(segment: segment)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Segment Operations

    private func deleteSegment(_ segment: TranscriptSegment) {
        meeting.segments.removeAll { $0.id == segment.id }
        modelContext.delete(segment)
        selectedSegmentIDs.remove(segment.id)
        try? modelContext.save()
    }

    private func deleteSelectedSegments() {
        let toDelete = meeting.segments.filter { selectedSegmentIDs.contains($0.id) }
        for segment in toDelete {
            meeting.segments.removeAll { $0.id == segment.id }
            modelContext.delete(segment)
        }
        selectedSegmentIDs.removeAll()
        try? modelContext.save()
    }

    private func mergeSegmentWithNext(_ segment: TranscriptSegment) {
        let sorted = sortedSegments
        guard let idx = sorted.firstIndex(where: { $0.id == segment.id }),
              idx + 1 < sorted.count else { return }

        let next = sorted[idx + 1]

        // Cache originals if not already edited
        if !segment.isEdited {
            segment.originalText = segment.text
            segment.originalSpeakerData = segment.speakerData
        }

        // Merge text and extend time range
        segment.text = segment.text + " " + next.text
        segment.endTime = next.endTime
        segment.isEdited = true

        // Remove the merged segment
        meeting.segments.removeAll { $0.id == next.id }
        modelContext.delete(next)
        selectedSegmentIDs.remove(next.id)
        try? modelContext.save()
    }

    private func splitSegment(_ segment: TranscriptSegment, before: String, after: String) {
        guard !before.isEmpty, !after.isEmpty else { return }

        // Calculate approximate split time based on text proportion
        let totalLength = Double(segment.text.count)
        let beforeLength = Double(before.count)
        let ratio = beforeLength / totalLength
        let splitTime = segment.startTime + (segment.endTime - segment.startTime) * ratio

        // Update original segment to be the "before" part
        if !segment.isEdited {
            segment.originalText = segment.text
            segment.originalSpeakerData = segment.speakerData
        }
        segment.text = before
        segment.endTime = splitTime
        segment.isEdited = true

        // Create new segment for the "after" part
        let newSegment = TranscriptSegment(
            speaker: segment.speaker,
            text: after,
            startTime: splitTime,
            endTime: segment.endTime,
            isFinal: true
        )
        newSegment.meeting = meeting
        meeting.segments.append(newSegment)
        try? modelContext.save()
    }

    private func reassignSelectedSegments(to speaker: Speaker) {
        for segment in meeting.segments where selectedSegmentIDs.contains(segment.id) {
            if !segment.isEdited {
                segment.originalText = segment.text
                segment.originalSpeakerData = segment.speakerData
            }
            segment.speaker = speaker
            segment.isEdited = true
        }
        try? modelContext.save()
    }

    private func revertAllEdits() {
        for segment in meeting.segments where segment.isEdited {
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
        try? modelContext.save()
    }

    private func toggleSelection(_ segment: TranscriptSegment) {
        if selectedSegmentIDs.contains(segment.id) {
            selectedSegmentIDs.remove(segment.id)
        } else {
            selectedSegmentIDs.insert(segment.id)
        }
    }

    // MARK: - Helpers

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

struct SeriesSectionView: View {
    let meeting: Meeting
    let seriesTitle: String

    @Query private var allMeetings: [Meeting]

    private var seriesMeetings: [Meeting] {
        guard let seriesID = meeting.seriesID else { return [] }
        return allMeetings
            .filter { $0.seriesID == seriesID && $0.id != meeting.id }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        if !seriesMeetings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Series: \(seriesTitle)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))

                ForEach(seriesMeetings.prefix(5)) { m in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(m.title)
                            .font(.caption)
                        Spacer()
                        Text(m.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

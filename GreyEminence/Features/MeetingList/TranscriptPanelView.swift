import SwiftUI
import SwiftData

struct TranscriptPanelView: View {
    @Bindable var meeting: Meeting
    var onSplitMeeting: ((Meeting) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @AppStorage("developerToolsEnabled") private var developerToolsEnabled = false

    @State private var selectedSegmentIDs: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showBulkDeleteConfirmation = false
    @State private var showBulkSpeakerPicker = false
    @State private var showBulkSpeakerRename = false
    @State private var bulkSpeakerName: String = ""
    @State private var splitConfirmationSegment: TranscriptSegment?
    @State private var isSplittingMeeting = false
    @State private var splitTask: Task<Void, Never>?
    @State private var sortedSegments: [TranscriptSegment] = []
    @State private var showDedupDebug = false
    @State private var editSaveError: String?

    private var editedCount: Int {
        meeting.segments.filter(\.isEdited).count
    }

    var body: some View {
        VStack(spacing: 0) {
            if meeting.status == .completed && !sortedSegments.isEmpty {
                transcriptToolbar
                Divider()
            }

            if let editSaveError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(editSaveError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { self.editSaveError = nil }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
            }

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
        .onAppear {
            sortedSegments = meeting.segments.sorted { $0.startTime < $1.startTime }
        }
        .onChange(of: meeting.segments.count) {
            sortedSegments = meeting.segments.sorted { $0.startTime < $1.startTime }
        }
        .overlay {
            if isSplittingMeeting {
                ZStack {
                    Color.black.opacity(0.25)
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Splitting meeting and re-analyzing...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Cancel") {
                            splitTask?.cancel()
                        }
                        .controlSize(.small)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
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
        .confirmationDialog(
            splitConfirmationTitle,
            isPresented: Binding(
                get: { splitConfirmationSegment != nil },
                set: { if !$0 { splitConfirmationSegment = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Split Into New Meeting") {
                if let segment = splitConfirmationSegment {
                    splitConfirmationSegment = nil
                    splitTask = Task { await splitMeeting(from: segment) }
                }
            }
            Button("Cancel", role: .cancel) {
                splitConfirmationSegment = nil
            }
        } message: {
            Text("This segment and everything after it will be moved into a new meeting. Both meetings will be re-analyzed by AI.")
        }
    }

    private var splitConfirmationTitle: String {
        guard let seg = splitConfirmationSegment else { return "Split Into New Meeting" }
        let preview = String(seg.text.prefix(60))
        return "Split from \"\(preview)\(seg.text.count > 60 ? "…" : "")\"?"
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

            if developerToolsEnabled {
                Toggle(isOn: $showDedupDebug) {
                    Label("Dedup Debug", systemImage: "magnifyingglass")
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Button("Remove Duplicates") {
                    deduplicateTranscript()
                }
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }

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
        let systemSegments = showDedupDebug ? sortedSegments.filter { !$0.speaker.isMe } : []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(sortedSegments) { segment in
                    if meeting.status == .completed {
                        EditableTranscriptSegmentRow(
                            segment: segment,
                            hasNext: sortedSegments.last?.id != segment.id,
                            isSelected: selectedSegmentIDs.contains(segment.id),
                            onDelete: { deleteSegment(segment) },
                            onMergeWithNext: { mergeSegmentWithNext(segment) },
                            onSplit: { before, after in splitSegment(segment, before: before, after: after) },
                            onSplitMeeting: {
                                if canSplitMeeting(at: segment) {
                                    splitConfirmationSegment = segment
                                }
                            },
                            onChangeSpeakerForAll: { newSpeaker in
                                changeSpeakerForAll(from: segment, to: newSpeaker)
                            },
                            onToggleSelection: isSelectionMode ? {
                                toggleSelection(segment)
                            } : nil
                        )
                    } else {
                        TranscriptSegmentRow(segment: segment)
                    }
                    if showDedupDebug && segment.speaker.isMe {
                        DedupDebugRow(
                            mic: segment,
                            systemSegments: systemSegments
                        )
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
        saveEdit(site: "deleteSegment")
    }

    private func deleteSelectedSegments() {
        let toDelete = meeting.segments.filter { selectedSegmentIDs.contains($0.id) }
        for segment in toDelete {
            meeting.segments.removeAll { $0.id == segment.id }
            modelContext.delete(segment)
        }
        selectedSegmentIDs.removeAll()
        saveEdit(site: "deleteSelectedSegments")
    }

    private func mergeSegmentWithNext(_ segment: TranscriptSegment) {
        let sorted = sortedSegments
        guard let idx = sorted.firstIndex(where: { $0.id == segment.id }),
              idx + 1 < sorted.count else { return }

        let next = sorted[idx + 1]

        if !segment.isEdited {
            segment.originalText = segment.text
            segment.originalSpeakerData = segment.speakerData
        }

        segment.text = segment.text + " " + next.text
        segment.endTime = next.endTime
        segment.isEdited = true

        meeting.segments.removeAll { $0.id == next.id }
        modelContext.delete(next)
        selectedSegmentIDs.remove(next.id)
        saveEdit(site: "mergeSegmentWithNext")
    }

    private func splitSegment(_ segment: TranscriptSegment, before: String, after: String) {
        guard !before.isEmpty, !after.isEmpty else { return }

        let totalLength = Double(segment.text.count)
        let beforeLength = Double(before.count)
        let ratio = beforeLength / totalLength
        let splitTime = segment.startTime + (segment.endTime - segment.startTime) * ratio

        if !segment.isEdited {
            segment.originalText = segment.text
            segment.originalSpeakerData = segment.speakerData
        }
        segment.text = before
        segment.endTime = splitTime
        segment.isEdited = true

        let newSegment = TranscriptSegment(
            speaker: segment.speaker,
            text: after,
            startTime: splitTime,
            endTime: segment.endTime,
            isFinal: true
        )
        newSegment.meeting = meeting
        meeting.segments.append(newSegment)
        saveEdit(site: "splitSegment")
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
        saveEdit(site: "reassignSelectedSegments")
    }

    private func deduplicateTranscript() {
        let snapshots = sortedSegments
        let result = TranscriptDeduplicator.deduplicate(snapshots)
        guard result.removedCount > 0 else { return }
        for removed in result.removedSegments {
            if let seg = meeting.segments.first(where: { $0.id == removed.id }) {
                modelContext.delete(seg)
            }
        }
        saveEdit(site: "deduplicateTranscript")
        sortedSegments = meeting.segments.sorted { $0.startTime < $1.startTime }
        LogManager.send("Manual dedup removed \(result.removedCount) segment(s)", category: .transcription)
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
        saveEdit(site: "revertAllEdits")
    }

    private func toggleSelection(_ segment: TranscriptSegment) {
        if selectedSegmentIDs.contains(segment.id) {
            selectedSegmentIDs.remove(segment.id)
        } else {
            selectedSegmentIDs.insert(segment.id)
        }
    }

    private func changeSpeakerForAll(from segment: TranscriptSegment, to newSpeaker: Speaker) {
        let currentSpeaker = segment.speaker
        for seg in meeting.segments where seg.speaker == currentSpeaker {
            if !seg.isEdited {
                seg.originalText = seg.text
                seg.originalSpeakerData = seg.speakerData
            }
            seg.speaker = newSpeaker
            seg.isEdited = true
        }
        saveEdit(site: "changeSpeakerForAll")
    }

    /// Persist a user edit and surface failures. Used by all segment-editing
    /// actions (delete, merge, split, reassign, dedup, revert). On failure
    /// we log and show a transient error banner — if the user doesn't know
    /// their edit was dropped, they'll lose work silently.
    private func saveEdit(site: String) {
        let ok = PersistenceGate.save(
            modelContext,
            site: "MeetingDetailView.\(site)",
            meetingID: meeting.id
        )
        if !ok {
            editSaveError = "Edit couldn't be saved: \(PersistenceGate.lastFailureMessage ?? "unknown error"). Try again, or check disk space."
        } else {
            editSaveError = nil
        }
    }

    // Only disallow splitting at the very first segment (nothing would remain in the original).
    private func canSplitMeeting(at segment: TranscriptSegment) -> Bool {
        guard sortedSegments.count >= 2 else { return false }
        guard let idx = sortedSegments.firstIndex(where: { $0.id == segment.id }) else { return false }
        return idx > 0
    }

    @MainActor
    private func splitMeeting(from splitSegment: TranscriptSegment) async {
        guard let splitIdx = sortedSegments.firstIndex(where: { $0.id == splitSegment.id }),
              splitIdx > 0 else { return }

        isSplittingMeeting = true
        defer {
            isSplittingMeeting = false
            splitTask = nil
        }

        let keepSegments = Array(sortedSegments[0..<splitIdx])
        let moveSegments = Array(sortedSegments[splitIdx...])

        let splitTime = splitSegment.startTime
        let newMeetingDate = meeting.date.addingTimeInterval(splitTime)
        let newMeeting = Meeting(
            title: "Meeting \(DateFormatter.shortDate.string(from: newMeetingDate))",
            date: newMeetingDate,
            duration: meeting.duration - splitTime,
            status: .completed
        )
        modelContext.insert(newMeeting)

        newMeeting.attendees = meeting.attendees

        for segment in moveSegments {
            segment.startTime -= splitTime
            segment.endTime -= splitTime
            segment.meeting = newMeeting
        }

        meeting.duration = keepSegments.last.map { $0.endTime } ?? splitTime

        for old in meeting.insights { modelContext.delete(old) }
        for old in meeting.actionItems { modelContext.delete(old) }
        for old in newMeeting.insights { modelContext.delete(old) }
        for old in newMeeting.actionItems { modelContext.delete(old) }

        let splitSplitOK = PersistenceGate.save(
            modelContext,
            site: "splitMeeting/afterSegmentMove",
            critical: true,
            meetingID: meeting.id
        )
        if !splitSplitOK {
            editSaveError = "Split failed while saving the new meeting layout — both meetings may be in an inconsistent state. Check the activity log and consider reverting."
            return
        }

        let originalSnapshots = meeting.segments
            .sorted { $0.startTime < $1.startTime }
            .map { SegmentSnapshot(speaker: $0.speaker, text: $0.text, formattedTimestamp: $0.formattedTimestamp, isFinal: $0.isFinal) }
        let newSnapshots = newMeeting.segments
            .sorted { $0.startTime < $1.startTime }
            .map { SegmentSnapshot(speaker: $0.speaker, text: $0.text, formattedTimestamp: $0.formattedTimestamp, isFinal: $0.isFinal) }

        guard let client = try? await AIClientFactory.makeClient() else {
            onSplitMeeting?(newMeeting)
            return
        }

        meeting.isAnalyzing = true
        newMeeting.isAnalyzing = true
        PersistenceGate.save(
            modelContext,
            site: "splitMeeting/markAnalyzing",
            meetingID: meeting.id
        )

        await analyzeMeetingAfterSplit(meeting, snapshots: originalSnapshots, client: client)
        if Task.isCancelled {
            newMeeting.isAnalyzing = false
            PersistenceGate.save(modelContext, site: "splitMeeting/cancelled", meetingID: meeting.id)
            onSplitMeeting?(newMeeting)
            return
        }
        await analyzeMeetingAfterSplit(newMeeting, snapshots: newSnapshots, client: client)

        let finalOK = PersistenceGate.save(
            modelContext,
            site: "splitMeeting/finalInsights",
            critical: true,
            meetingID: meeting.id
        )
        if !finalOK {
            editSaveError = "Split re-analysis completed but saving insights failed. Both meetings have transcripts but may be missing AI insights — use Reanalyze to retry."
        }

        onSplitMeeting?(newMeeting)
    }

    private func analyzeMeetingAfterSplit(_ target: Meeting, snapshots: [SegmentSnapshot], client: any AIClient) async {
        guard !snapshots.isEmpty else {
            target.isAnalyzing = false
            return
        }

        let service = AIIntelligenceService(client: client, meetingID: target.id)
        do {
            _ = try await service.analyze(segments: snapshots)
            if let result = try await service.performFinalAnalysis(segments: snapshots) {
                if let title = result.title, !title.isEmpty {
                    target.title = title
                }
                let insight = MeetingInsight(
                    summary: result.summary,
                    followUpQuestions: result.followUps,
                    topics: result.topics,
                    rawLLMResponse: result.rawResponse,
                    modelIdentifier: client.modelIdentifier,
                    promptVersion: AIPromptTemplates.promptVersion
                )
                insight.meeting = target
                target.insights.append(insight)
                for parsed in result.actionItems {
                    let item = ActionItem(text: parsed.text, assignee: parsed.assignee)
                    item.meeting = target
                    target.actionItems.append(item)
                }
            }
        } catch {
            LogManager.send("Split meeting analysis failed: \(error.localizedDescription)", category: .ai, level: .error)
        }
        target.isAnalyzing = false
    }
}

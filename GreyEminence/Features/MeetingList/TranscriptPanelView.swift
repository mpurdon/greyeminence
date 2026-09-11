import SwiftUI
import SwiftData

struct TranscriptPanelView: View {
    /// Bumped after a manual reassignment so the identity bar recomputes.
    @State private var speakerIdentityRefresh = 0

    @Bindable var meeting: Meeting
    var onSplitMeeting: ((Meeting) -> Void)?
    @Binding var scrollToSegmentID: UUID?
    /// When set, segment timestamps become click targets that seek the
    /// screen-share player.
    var onSeekToTime: ((TimeInterval) -> Void)?

    init(meeting: Meeting, onSplitMeeting: ((Meeting) -> Void)? = nil, scrollToSegmentID: Binding<UUID?> = .constant(nil), onSeekToTime: ((TimeInterval) -> Void)? = nil) {
        self._meeting = Bindable(wrappedValue: meeting)
        self.onSplitMeeting = onSplitMeeting
        self._scrollToSegmentID = scrollToSegmentID
        self.onSeekToTime = onSeekToTime
    }

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
    @State private var highlightedSegmentID: UUID?
    @State private var sortedSegments: [TranscriptSegment] = []
    /// When set, the list shows only this voice. A view filter — nothing is
    /// deleted, and every edit action still works on the full transcript.
    @State private var filteredSpeaker: Speaker?
    @State private var roster = TranscriptSpeakerRoster()
    @State private var showDedupDebug = false
    @State private var isCorrecting = false
    @State private var correctionStatus: String?
    @State private var editSaveError: String?

    private var editedCount: Int {
        // Allocation-free scan — read on every body evaluation, so avoid
        // building a throwaway filtered array of up to a few thousand segments.
        meeting.segments.reduce(into: 0) { count, segment in
            if segment.isEdited { count += 1 }
        }
    }

    /// Rebuild the sorted list and the speaker roster together. The roster
    /// is cached rather than computed per body evaluation: it decodes a
    /// `Speaker` out of every segment, and the toolbar reads it on every
    /// update of a view that can hold a few thousand of them.
    private func rebuildSegments() {
        sortedSegments = meeting.segments.sorted { $0.startTime < $1.startTime }
        roster = TranscriptSpeakerRoster.build(
            speakers: sortedSegments.map { ($0.speaker, $0.endTime - $0.startTime) }
        )
        if let filtered = filteredSpeaker, roster.entry(for: filtered) == nil {
            // The voice was renamed or reassigned away entirely — drop a
            // filter that can only show an empty list.
            filteredSpeaker = nil
        }
    }

    /// The rows on screen. Only the list reads this: merging, splitting and
    /// dedup index into `sortedSegments`, and filtering that would silently
    /// join lines that aren't adjacent in the meeting.
    private var visibleSegments: [TranscriptSegment] {
        guard let filteredSpeaker else { return sortedSegments }
        return sortedSegments.filter { $0.speaker == filteredSpeaker }
    }

    var body: some View {
        VStack(spacing: 0) {
            SpeakerIdentityBar(
                meeting: meeting,
                refreshToken: speakerIdentityRefresh,
                onFilterSpeaker: { label in filteredSpeaker = .other(label) }
            )
                .onChange(of: meeting.segments.count) { _, _ in speakerIdentityRefresh += 1 }
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
            } else if visibleSegments.isEmpty, let filteredSpeaker {
                // Reachable after reassigning the last line of a voice while
                // filtered to it — offer the way back rather than a dead end.
                ContentUnavailableView {
                    Label("No lines from \(filteredSpeaker.displayName)", systemImage: "person.slash")
                } description: {
                    Text("This voice has no remaining lines in the transcript.")
                } actions: {
                    Button("Show All Speakers") { self.filteredSpeaker = nil }
                }
            } else {
                transcriptList
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            rebuildSegments()
        }
        .onChange(of: meeting.segments.count) {
            rebuildSegments()
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

    // MARK: - Mis-hearing correction

    /// Runs the correction pass on the transcript as it stands — no
    /// re-transcription — so a meeting processed before the pass existed
    /// can be fixed on demand.
    private func runCorrection() {
        isCorrecting = true
        correctionStatus = nil
        Task { @MainActor in
            let fixed = await ReProcessingQueue.shared.correctTranscript(for: meeting, in: modelContext)
            correctionStatus = fixed == 0 ? "No mis-hearings found" : "\(fixed) line\(fixed == 1 ? "" : "s") corrected"
            isCorrecting = false
        }
    }

    // MARK: - Transcript Toolbar

    /// Three classes of control live here, and treating them as peers in one
    /// row is what made this unreadable: selection actions are *modal* (they
    /// exist only while selecting), the developer tools serve a different
    /// audience entirely, and Revert is ambient and rare. So the bar switches
    /// between a resting state and a selection state rather than accumulating
    /// controls, and the developer tools get their own strip.
    private var transcriptToolbar: some View {
        VStack(spacing: 0) {
            if isSelectionMode {
                selectionBar
            } else {
                restingBar
            }
            if filteredSpeaker != nil {
                speakerFilterBanner
            }
            if developerToolsEnabled {
                developerStrip
            }
        }
        .background(.bar)
    }

    /// Reading, not editing. One action in, and whatever the transcript's own
    /// state warrants — nothing else competes for the row.
    private var restingBar: some View {
        HStack(spacing: 8) {
            Button {
                isSelectionMode = true
            } label: {
                Label("Select", systemImage: "checklist")
            }
            .controlSize(.small)

            if roster.isFilterable {
                speakerFilterMenu
            }

            Button {
                runCorrection()
            } label: {
                Label(isCorrecting ? "Fixing…" : "Fix Mis-hearings", systemImage: "sparkles")
            }
            .controlSize(.small)
            .disabled(isCorrecting)
            .help("Ask the AI to repair words the recogniser misheard. Only phonetic slips that make no sense in context are changed; each fix keeps the original on hover.")

            if let correctionStatus {
                Text(correctionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if editedCount > 0 {
                Button("Revert All Edits") {
                    revertAllEdits()
                }
                .controlSize(.small)
                .foregroundStyle(.orange)
            }
        }
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// Selection takes over the bar rather than adding to it, so every control
    /// present acts on the selection. Actions that need a selection appear
    /// only once there is one — the bar grows with intent instead of showing
    /// dead buttons. It flows to a second row in a narrow panel, which reads
    /// as deliberate because everything wrapping belongs to one task.
    private var selectionBar: some View {
        // Centred because this row mixes a caption with bordered controls.
        FlowLayout(spacing: 8, rowAlignment: .center) {
            Button {
                isSelectionMode = false
                selectedSegmentIDs.removeAll()
            } label: {
                Label("Done", systemImage: "checkmark.circle")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)

            Button(allSegmentsSelected ? "Select None" : "Select All") {
                if allSegmentsSelected {
                    selectedSegmentIDs.removeAll()
                } else {
                    selectedSegmentIDs = Set(visibleSegments.map(\.id))
                }
            }
            .controlSize(.small)

            if selectedSegmentIDs.isEmpty {
                Text("Choose segments to edit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(selectedSegmentIDs.count) selected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Menu {
                    Button("Choose Contact…") {
                        showBulkSpeakerPicker = true
                    }
                    Button("Type Name…") {
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

                Button(role: .destructive) {
                    showBulkDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
    }

    /// Which voice the list is showing. A menu rather than a row of chips:
    /// a long call can have eight speakers, and the toolbar already carries
    /// three other controls.
    @ViewBuilder
    private var speakerFilterMenu: some View {
        Menu {
            Button {
                filteredSpeaker = nil
            } label: {
                if filteredSpeaker == nil {
                    Label("All Speakers", systemImage: "checkmark")
                } else {
                    Text("All Speakers")
                }
            }
            Divider()
            ForEach(roster.entries) { entry in
                Button {
                    filteredSpeaker = entry.speaker
                } label: {
                    let detail = "\(entry.displayName)  ·  \(entry.segmentCount) line\(entry.segmentCount == 1 ? "" : "s"), \(entry.durationLabel)"
                    if filteredSpeaker == entry.speaker {
                        Label(detail, systemImage: "checkmark")
                    } else {
                        Text(detail)
                    }
                }
            }
        } label: {
            Label(
                filteredSpeaker?.displayName ?? "All Speakers",
                systemImage: filteredSpeaker == nil ? "person.2" : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .controlSize(.small)
        .fixedSize()
        .help("Show only one speaker's lines")
    }

    /// Says what is hidden. Without it a filtered transcript reads as a
    /// transcript that lost most of its content.
    private var speakerFilterBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("Showing \(visibleSegments.count) of \(sortedSegments.count) lines — \(filteredSpeaker?.displayName ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Show All") { filteredSpeaker = nil }
                .controlSize(.small)
        }
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }

    /// Diagnostics, not editing. Kept in its own strip and labelled as such so
    /// it never reads as part of the transcript workflow — these tools inspect
    /// and repair the pipeline's output rather than the meeting's content.
    private var developerStrip: some View {
        HStack(spacing: 10) {
            StatusPill(label: "DEV", tint: .secondary)

            Toggle("Dedup debug", isOn: $showDedupDebug)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)

            Spacer(minLength: 8)

            Button("Remove Duplicates") {
                deduplicateTranscript()
            }
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Divider() }
    }

    /// "Select All" means everything on screen. While a speaker filter is
    /// on, selecting the whole transcript and bulk-reassigning it is exactly
    /// the mistake this scoping prevents.
    private var allSegmentsSelected: Bool {
        let visible = visibleSegments
        return !visible.isEmpty && visible.allSatisfy { selectedSegmentIDs.contains($0.id) }
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        let systemSegments = showDedupDebug ? sortedSegments.filter { !$0.speaker.isMe } : []
        let userLevelBaseline: Float? = showDedupDebug
            ? TranscriptDeduplicator.userLevelBaseline(
                micSegments: sortedSegments.filter(\.speaker.isMe),
                systemSegments: systemSegments,
                sysMids: systemSegments.map { ($0.startTime + $0.endTime) / 2 }
            )
            : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleSegments) { segment in
                        transcriptRow(segment, systemSegments: systemSegments, userLevelBaseline: userLevelBaseline)
                            .id(segment.id)
                            .padding(.vertical, 2)
                            .background(
                                highlightedSegmentID == segment.id
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                }
                .padding()
            }
            .onChange(of: scrollToSegmentID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
                highlightedSegmentID = newID
                scrollToSegmentID = nil
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if highlightedSegmentID == newID {
                        withAnimation { highlightedSegmentID = nil }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ segment: TranscriptSegment, systemSegments: [TranscriptSegment], userLevelBaseline: Float?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    } : nil,
                    onSeekToTime: onSeekToTime,
                    onFilterSpeaker: { speaker in
                        filteredSpeaker = (filteredSpeaker == speaker) ? nil : speaker
                    },
                    onPlayAudio: { SegmentAudioPlayer.shared.toggle(segment, in: meeting) },
                    isPlayingAudio: SegmentAudioPlayer.shared.playingSegmentID == segment.id,
                    playbackFailure: SegmentAudioPlayer.shared.failure?.segmentID == segment.id
                        ? SegmentAudioPlayer.shared.failure?.message : nil
                )
            } else {
                TranscriptSegmentRow(segment: segment)
            }
            if showDedupDebug && segment.speaker.isMe {
                DedupDebugRow(mic: segment, systemSegments: systemSegments, userLevelBaseline: userLevelBaseline)
            }
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
        speakerIdentityRefresh += 1
        saveEdit(site: "reassignSelectedSegments")
        rebuildSegments()
    }

    private func deduplicateTranscript() {
        let snapshots = sortedSegments
        let result = TranscriptDeduplicator.deduplicate(snapshots)
        guard result.removedCount > 0 || result.reassignedCount > 0 else { return }
        for removed in result.removedSegments {
            if let seg = meeting.segments.first(where: { $0.id == removed.id }) {
                modelContext.delete(seg)
            }
        }
        saveEdit(site: "deduplicateTranscript")
        rebuildSegments()
        LogManager.send("Manual dedup removed \(result.removedCount) segment(s), reattributed \(result.reassignedCount) quiet line(s)", category: .transcription)
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
        newMeeting.absentAttendeeIDs = meeting.absentAttendeeIDs

        // Audio files aren't physically split — we record offsets into the
        // source meeting's audio timeline. If the meeting being split is
        // itself a child, preserve the original root and compound the
        // offsets so re-transcription walks the right chunks.
        let rootSource = meeting.audioSourceMeetingID ?? meeting.id
        let rootOffset = meeting.audioStartOffset
        newMeeting.audioSourceMeetingID = rootSource
        newMeeting.audioStartOffset = rootOffset + splitTime
        newMeeting.audioEndOffset = meeting.audioEndOffset
        // The meeting we're splitting now ends at the split point in the
        // source timeline.
        meeting.audioEndOffset = rootOffset + splitTime

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

        let service = AIIntelligenceService(
            client: client,
            meetingID: target.id,
            relatedContextProvider: RelatedMeetingContext.provider(excludingMeetingID: target.id)
        )
        do {
            let roster = MeetingRoster.snapshot(for: target)
            let finalResult = try await AIUsageContext.attribute(.reanalysis, meetingID: target.id) {
                _ = try await service.analyze(segments: snapshots, roster: roster)
                return try await service.performFinalAnalysis(segments: snapshots, roster: roster)
            }
            if let result = finalResult {
                if let title = result.title {
                    target.applyGeneratedTitle(title)
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
                    let item = ActionItem(parsed: parsed, sourceSegments: target.segments)
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

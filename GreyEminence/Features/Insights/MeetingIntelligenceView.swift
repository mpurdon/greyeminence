import SwiftUI
import SwiftData

struct MeetingIntelligenceView: View {
    @Bindable var meeting: Meeting
    /// Screen-share player sync (optional — only the meeting/archive detail
    /// panes wire these; other hosts get a self-contained player).
    var pendingSeekTime: Binding<TimeInterval?> = .constant(nil)
    var onPlayheadSegment: ((UUID) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var isReanalyzing = false
    @State private var reanalysisError: String?
    @State private var reanalyzeTask: Task<Void, Never>?
    @State private var reanalyzeSharesTrigger = false
    @State private var isExportingReport = false
    @State private var exportError: String?
    @State private var showExportSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label {
                        Text("Meeting Intelligence")
                    } icon: {
                        Image(systemName: "brain")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .font(.headline)

                    Spacer()

                    // Truncates first when the pane narrows — the Reanalyze
                    // controls must never be pushed off screen by a caption.
                    MeetingAIUsageCaption(meetingID: meeting.id, isAnalyzing: isReanalyzing || meeting.isAnalyzing)
                        .layoutPriority(-1)

                    if meeting.status == .completed {
                        if isExportingReport {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Exporting…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button {
                                showExportSheet = true
                            } label: {
                                Label("Export PDF", systemImage: "doc.richtext")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Choose what to include, then export as a PDF report")
                        }
                    }

                    if meeting.status == .completed && !meeting.segments.isEmpty {
                        if isReanalyzing || meeting.isAnalyzing {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Analyzing...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    cancelAnalysis()
                                } label: {
                                    Label("Cancel", systemImage: "stop.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Cancel the in-progress analysis and reset the meeting state")
                            }
                        } else {
                            Menu {
                                Button {
                                    ReProcessingQueue.shared.enqueue(meetingID: meeting.id)
                                } label: {
                                    Label("Re-transcribe with large-v3", systemImage: "waveform.badge.checkmark")
                                }
                                if !meeting.screenFrames.isEmpty {
                                    Button {
                                        reanalyzeSharesTrigger = true
                                    } label: {
                                        Label("Re-analyze screen shares", systemImage: "rectangle.dashed.badge.record")
                                    }
                                }
                            } label: {
                                Label("Reanalyze", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            } primaryAction: {
                                reanalyzeTask = Task { await reanalyze() }
                            }
                            .menuStyle(.button)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                            .help("Click: re-run AI on the current transcript. Arrow: full re-transcription with large-v3.")
                        }
                    }
                }
                .padding(.horizontal)

                if let error = exportError ?? reanalysisError ?? meeting.analysisError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") {
                            exportError = nil
                            reanalysisError = nil
                            meeting.analysisError = nil
                        }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }
                    .padding(.horizontal)
                }

                ScreenSharePlayerSection(
                    meeting: meeting,
                    pendingSeekTime: pendingSeekTime,
                    onPlayheadSegment: onPlayheadSegment,
                    reanalyzeSharesTrigger: $reanalyzeSharesTrigger
                )

                if let insight = meeting.latestInsight {
                    FollowUpQuestionsSection(questions: insight.followUpQuestions) { index in
                        let question = insight.followUpQuestions[index]
                        let key = Self.normalizeKey(question)
                        if !meeting.suppressedFollowUps.contains(key) {
                            meeting.suppressedFollowUps.append(key)
                        }
                        insight.followUpQuestions.remove(at: index)
                        PersistenceGate.save(modelContext, site: "MeetingIntelligenceView.deleteFollowUp", meetingID: meeting.id)
                    }
                    ActionItemsSection(items: meeting.actionItems) { item in
                        let key = Self.normalizeKey(item.text)
                        if !meeting.suppressedActionItems.contains(key) {
                            meeting.suppressedActionItems.append(key)
                        }
                        modelContext.delete(item)
                        PersistenceGate.save(modelContext, site: "MeetingIntelligenceView.deleteActionItem", meetingID: meeting.id)
                    }
                    AISummarySection(summary: insight.summary)
                    KnowledgeLinksSection(topics: insight.topics)
                } else if meeting.isAnalyzing || isReanalyzing {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(isReanalyzing ? "Reanalyzing meeting..." : "Analyzing meeting...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 60)
                } else {
                    ContentUnavailableView(
                        "No Insights Yet",
                        systemImage: "brain",
                        description: Text("AI-powered insights will appear after recording")
                    )
                }
            }
            .padding(.vertical)
        }
        .sheet(isPresented: $showExportSheet) {
            ReportExportSheet(meeting: meeting) { options in
                exportReport(options)
            }
        }
    }

    private func exportReport(_ options: ReportExportOptions) {
        guard !isExportingReport else { return }
        isExportingReport = true
        exportError = nil
        Task { @MainActor in
            defer { isExportingReport = false }
            do {
                if let url = try await ReportExportService.exportPDF(for: meeting, options: options) {
                    // Reveal rather than open: the user almost always wants to
                    // attach or send the file next, not read it in Preview.
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func reanalyze() async {
        guard !isReanalyzing else { return }
        isReanalyzing = true
        reanalysisError = nil
        meeting.analysisError = nil

        defer { isReanalyzing = false }

        do {
            guard let client = try await AIClientFactory.makeClient() else {
                reanalysisError = "AI not configured. Check Settings."
                return
            }
            let service = AIIntelligenceService(
                client: client,
                meetingID: meeting.id,
                suppressedActionItems: meeting.suppressedActionItems,
                suppressedFollowUps: meeting.suppressedFollowUps,
                relatedContextProvider: RelatedMeetingContext.provider(excludingMeetingID: meeting.id)
            )

            let snapshots: [SegmentSnapshot] = meeting.segments
                .sorted { $0.startTime < $1.startTime }
                .map { SegmentSnapshot(speaker: $0.speaker, text: $0.text, formattedTimestamp: $0.formattedTimestamp, isFinal: $0.isFinal) }

            guard !snapshots.isEmpty else {
                reanalysisError = "No transcript segments to analyze."
                return
            }

            // Seed with analyze() first so performFinalAnalysis has a prior
            // summary to refine. Then always run the final pass — it produces
            // the polished result including the meeting title. Screen-share
            // observations persisted on the frames ride along so a re-run
            // stays screen-aware like the original live analysis.
            let roster = MeetingRoster.snapshot(for: meeting)
            let screenBlock = ScreenObservationFormatter.finalBlock(for: meeting)
            if screenBlock != nil {
                LogManager.shared.log("Reanalyze: injecting screen context (\(meeting.sessionSummaries.count) recap(s), \(meeting.screenFrames.count) frame(s))", category: .screen, meetingID: meeting.id)
            }
            let maybeResult = try await AIUsageContext.attribute(.reanalysis, meetingID: meeting.id) {
                _ = try await service.analyze(segments: snapshots, roster: roster, screenObservations: screenBlock)
                return try await service.performFinalAnalysis(segments: snapshots, roster: roster, screenObservations: screenBlock)
            }
            guard let rawResult = maybeResult else {
                reanalysisError = "Analysis returned no results."
                return
            }

            // Belt-and-braces: enforce the user's suppression list locally even if
            // the model ignored the prompt instruction and re-suggested items.
            let suppressedActions = Set(meeting.suppressedActionItems)
            let suppressedQuestions = Set(meeting.suppressedFollowUps)
            let result = AnalysisResult(
                title: rawResult.title,
                summary: rawResult.summary,
                actionItems: rawResult.actionItems.filter { !suppressedActions.contains(Self.normalizeKey($0.text)) },
                followUps: rawResult.followUps.filter { !suppressedQuestions.contains(Self.normalizeKey($0)) },
                topics: rawResult.topics,
                rawResponse: rawResult.rawResponse,
                refinement: rawResult.refinement
            )

            // Update meeting title if generated (kept out of `title` while the
            // meeting is linked to a calendar event).
            if let title = result.title {
                meeting.applyGeneratedTitle(title)
            }
            meeting.applyRefinementSignal(result.refinement)

            // Persist new insight (append; keep history of prior insights)
            let insight = MeetingInsight(
                summary: result.summary,
                followUpQuestions: result.followUps,
                topics: result.topics,
                rawLLMResponse: result.rawResponse,
                modelIdentifier: client.modelIdentifier,
                promptVersion: AIPromptTemplates.promptVersion
            )
            insight.meeting = meeting
            modelContext.insert(insight)

            // Merge action items: preserve any with user state (completed, due date,
            // assigned contact) and add new parsed items that don't already exist by text.
            mergeActionItems(parsed: result.actionItems, into: meeting)

            let saved = PersistenceGate.save(
                modelContext,
                site: "MeetingIntelligenceView.reanalyze",
                critical: true,
                meetingID: meeting.id
            )
            if !saved {
                reanalysisError = "Reanalysis succeeded but saving to database failed: \(PersistenceGate.lastFailureMessage ?? "unknown")"
            }
        } catch {
            reanalysisError = error.localizedDescription
            LogManager.send("Reanalysis failed: \(error.localizedDescription)", category: .ai, level: .error)
        }
    }

    @MainActor
    private func cancelAnalysis() {
        reanalyzeTask?.cancel()
        reanalyzeTask = nil
        isReanalyzing = false
        meeting.isAnalyzing = false
        meeting.analysisError = "Analysis canceled by user."
        PersistenceGate.save(
            modelContext,
            site: "MeetingIntelligenceView.cancelAnalysis",
            meetingID: meeting.id
        )
        LogManager.send("Analysis canceled for meeting \(meeting.id)", category: .ai, level: .info)
    }

    /// Merges AI-parsed action items into the meeting while preserving user state
    /// (completion, due dates, assigned contacts). Existing items with matching
    /// normalized text are kept; new parsed items are appended. Items the user has
    /// already completed or assigned are never deleted by a re-run.
    private func mergeActionItems(parsed: [ParsedActionItem], into meeting: Meeting) {
        let existing = meeting.actionItems
        let existingKeys = Set(existing.map { Self.normalizeKey($0.text) })
        let suppressedKeys = Set(meeting.suppressedActionItems)

        // Delete only existing items that have no user state attached AND that the
        // new parse no longer produces. This keeps the list fresh for unstarted items
        // while protecting anything the user has touched.
        let parsedKeys = Set(parsed.map { Self.normalizeKey($0.text) })
        let stale = existing.filter { item in
            let untouched = !item.isCompleted
                && item.dueDate == nil
                && item.assignedContact == nil
            let droppedByNewRun = !parsedKeys.contains(Self.normalizeKey(item.text))
            return untouched && droppedByNewRun
        }
        for item in stale {
            modelContext.delete(item)
        }

        // Append new parsed items that don't already exist and aren't suppressed.
        for parsedItem in parsed {
            let key = Self.normalizeKey(parsedItem.text)
            guard !existingKeys.contains(key), !suppressedKeys.contains(key) else { continue }
            let item = ActionItem(parsed: parsedItem, sourceSegments: meeting.segments)
            item.meeting = meeting
            modelContext.insert(item)
        }
    }

    /// Normalized key for action-item deduping: lowercased, whitespace-collapsed,
    /// trailing punctuation stripped.
    private static func normalizeKey(_ text: String) -> String {
        let lowered = text.lowercased()
        let collapsed = lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:"))
    }
}

struct LiveMeetingIntelligenceView: View {
    let summary: String
    let actionItems: [ActionItem]
    let followUpQuestions: [String]
    let topics: [String]
    var aiActivityState: RecordingViewModel.AIActivityState = .idle
    var shareObservations: [ScreenFrameAnalysisService.FrameObservation] = []
    var isCapturingShare: Bool = false
    /// The in-progress meeting, when there is one. Everything else here is a
    /// plain value; this is needed because the screenshot player reads frames
    /// from the model, and without it a live recording could only ever show
    /// the observations as text.
    var meeting: Meeting?

    private var hasResults: Bool {
        !summary.isEmpty || !actionItems.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    Text("Meeting Intelligence")
                } icon: {
                    Image(systemName: "brain")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .font(.headline)
                .padding(.horizontal)

                if hasResults {
                    // Show a status line for subsequent cycles
                    if case .waiting(let secs) = aiActivityState {
                        HStack(spacing: 4) {
                            Image(systemName: "brain")
                                .font(.caption2)
                            Text("Next analysis in \(secs)s")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    } else if case .analyzing = aiActivityState {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Updating analysis...")
                                .font(.caption)
                        }
                        .foregroundStyle(.purple)
                        .padding(.horizontal)
                    }
                }

                if !followUpQuestions.isEmpty {
                    FollowUpQuestionsSection(questions: followUpQuestions)
                }

                if !actionItems.isEmpty {
                    LiveActionItemsSection(items: actionItems)
                }

                if !summary.isEmpty {
                    AISummarySection(summary: summary)
                }

                // Thumbnails once frames exist; the text list is the fallback
                // for the window between a share starting and its first frame
                // being captured, when there is something to say but nothing
                // to show yet.
                if let meeting, !meeting.screenFrames.isEmpty {
                    // No transcript sync while recording: the live view has
                    // no playhead to drive, so the seek binding is inert.
                    ScreenSharePlayerSection(meeting: meeting, pendingSeekTime: .constant(nil))
                } else if !shareObservations.isEmpty {
                    LiveSharedContentSection(
                        observations: shareObservations,
                        isCapturing: isCapturingShare
                    )
                }

                if !topics.isEmpty {
                    KnowledgeLinksSection(topics: topics)
                }

                if !hasResults {
                    switch aiActivityState {
                    case .waiting(let secs):
                        ContentUnavailableView {
                            Label("Waiting to Analyze", systemImage: "brain")
                        } description: {
                            Text("First analysis in \(secs)s...")
                        }
                    case .analyzing:
                        ContentUnavailableView {
                            Label("Analyzing Transcript", systemImage: "brain")
                        } description: {
                            Text("Processing your meeting transcript...")
                        }
                    case .idle:
                        ContentUnavailableView(
                            "Waiting...",
                            systemImage: "brain",
                            description: Text("AI insights will appear once analysis begins")
                        )
                    }
                }
            }
            .padding(.vertical)
        }
    }
}

/// "AI: 142k in / 9k out (~$0.31)" — the meeting's usage-ledger rollup,
/// with the per-purpose breakdown in the tooltip. Hidden until the ledger
/// has events for this meeting.
struct MeetingAIUsageCaption: View {
    let meetingID: UUID
    /// Re-fetches when an analysis finishes so the number stays current.
    var isAnalyzing: Bool = false
    @Environment(\.modelContext) private var modelContext
    @State private var totals: AIUsageAggregator.Totals?
    @State private var breakdown: [AIUsageAggregator.GroupRollup] = []

    var body: some View {
        Group {
            if let totals, totals.totalInputSideTokens + totals.outputTokens > 0 {
                Text(caption(totals))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(tooltip)
            }
        }
        .task(id: "\(meetingID)-\(isAnalyzing)") { refresh() }
    }

    private func refresh() {
        let id: UUID? = meetingID
        let descriptor = FetchDescriptor<AIUsageEvent>(predicate: #Predicate { $0.meetingID == id })
        let events = (try? modelContext.fetch(descriptor)) ?? []
        let lines = events.map(AIUsageAggregator.Line.init(event:))
        let settings = TrajectorSettings.load()
        totals = AIUsageAggregator.totals(lines, settings: settings)
        breakdown = AIUsageAggregator.byGroup(lines, settings: settings)
    }

    private func caption(_ totals: AIUsageAggregator.Totals) -> String {
        var text = "AI: \(AIUsageAggregator.compactTokens(totals.totalInputSideTokens)) in / \(AIUsageAggregator.compactTokens(totals.outputTokens)) out"
        if totals.estimatedCost > 0 {
            let approx = totals.pricedEverything ? "~" : ">"
            text += String(format: " (%@$%.2f)", approx, totals.estimatedCost)
        }
        return text
    }

    private var tooltip: String {
        var lines = breakdown.map { rollup in
            var line = "\(rollup.group.displayName): \(AIUsageAggregator.compactTokens(rollup.totals.totalInputSideTokens)) in / \(AIUsageAggregator.compactTokens(rollup.totals.outputTokens)) out"
            if rollup.totals.estimatedCost > 0 {
                line += String(format: " (~$%.2f)", rollup.totals.estimatedCost)
            }
            return line
        }
        if totals?.pricedEverything == false {
            lines.append("Some calls used a model without a known price — cost shown is a lower bound.")
        }
        return lines.joined(separator: "\n")
    }
}

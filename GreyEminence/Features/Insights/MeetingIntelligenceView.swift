import SwiftUI
import SwiftData

struct MeetingIntelligenceView: View {
    @Bindable var meeting: Meeting
    @Environment(\.modelContext) private var modelContext
    @State private var isReanalyzing = false
    @State private var reanalysisError: String?

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

                    if meeting.status == .completed && !meeting.segments.isEmpty {
                        if isReanalyzing || meeting.isAnalyzing {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Analyzing...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button {
                                Task { await reanalyze() }
                            } label: {
                                Label("Reanalyze", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Re-run AI analysis on this transcript")
                        }
                    }
                }
                .padding(.horizontal)

                if let error = reanalysisError ?? meeting.analysisError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") {
                            reanalysisError = nil
                            meeting.analysisError = nil
                        }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }
                    .padding(.horizontal)
                }

                if let insight = meeting.latestInsight {
                    AISummarySection(summary: insight.summary)
                    ActionItemsSection(items: meeting.actionItems) { item in
                        modelContext.delete(item)
                        PersistenceGate.save(modelContext, site: "MeetingIntelligenceView.deleteActionItem", meetingID: meeting.id)
                    }
                    FollowUpQuestionsSection(questions: insight.followUpQuestions) { index in
                        insight.followUpQuestions.remove(at: index)
                        PersistenceGate.save(modelContext, site: "MeetingIntelligenceView.deleteFollowUp", meetingID: meeting.id)
                    }
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
            let service = AIIntelligenceService(client: client, meetingID: meeting.id)

            let snapshots: [SegmentSnapshot] = meeting.segments
                .sorted { $0.startTime < $1.startTime }
                .map { SegmentSnapshot(speaker: $0.speaker, text: $0.text, formattedTimestamp: $0.formattedTimestamp, isFinal: $0.isFinal) }

            guard !snapshots.isEmpty else {
                reanalysisError = "No transcript segments to analyze."
                return
            }

            // Seed with analyze() first so performFinalAnalysis has a prior
            // summary to refine. Then always run the final pass — it produces
            // the polished result including the meeting title.
            _ = try await service.analyze(segments: snapshots)
            guard let result = try await service.performFinalAnalysis(segments: snapshots) else {
                reanalysisError = "Analysis returned no results."
                return
            }

            // Update meeting title if generated
            if let title = result.title, !title.isEmpty {
                meeting.title = title
            }

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

    /// Merges AI-parsed action items into the meeting while preserving user state
    /// (completion, due dates, assigned contacts). Existing items with matching
    /// normalized text are kept; new parsed items are appended. Items the user has
    /// already completed or assigned are never deleted by a re-run.
    private func mergeActionItems(parsed: [ParsedActionItem], into meeting: Meeting) {
        let existing = meeting.actionItems
        let existingKeys = Set(existing.map { Self.actionItemKey($0.text) })

        // Delete only existing items that have no user state attached AND that the
        // new parse no longer produces. This keeps the list fresh for unstarted items
        // while protecting anything the user has touched.
        let parsedKeys = Set(parsed.map { Self.actionItemKey($0.text) })
        let stale = existing.filter { item in
            let untouched = !item.isCompleted
                && item.dueDate == nil
                && item.assignedContact == nil
            let droppedByNewRun = !parsedKeys.contains(Self.actionItemKey(item.text))
            return untouched && droppedByNewRun
        }
        for item in stale {
            modelContext.delete(item)
        }

        // Append new parsed items that don't already exist.
        for parsedItem in parsed where !existingKeys.contains(Self.actionItemKey(parsedItem.text)) {
            let item = ActionItem(text: parsedItem.text, assignee: parsedItem.assignee)
            item.meeting = meeting
            modelContext.insert(item)
        }
    }

    /// Normalized key for action-item deduping: lowercased, whitespace-collapsed,
    /// trailing punctuation stripped.
    private static func actionItemKey(_ text: String) -> String {
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

                if !summary.isEmpty {
                    AISummarySection(summary: summary)
                }

                if !actionItems.isEmpty {
                    LiveActionItemsSection(items: actionItems)
                }

                if !followUpQuestions.isEmpty {
                    FollowUpQuestionsSection(questions: followUpQuestions)
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

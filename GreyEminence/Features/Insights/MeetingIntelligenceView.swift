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

                    if meeting.status == .completed && !meeting.segments.isEmpty && !isReanalyzing && !meeting.isAnalyzing {
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
                .padding(.horizontal)

                if let error = reanalysisError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") { reanalysisError = nil }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }
                    .padding(.horizontal)
                }

                if let insight = meeting.latestInsight {
                    AISummarySection(summary: insight.summary)
                    ActionItemsSection(items: meeting.actionItems)
                    FollowUpQuestionsSection(questions: insight.followUpQuestions)
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

            // Seed with analyze() first; performFinalAnalysis needs a prior summary to produce output.
            let firstPass = try await service.analyze(segments: snapshots)
            let result: AnalysisResult
            if let r = firstPass {
                result = r
            } else if let r = try await service.performFinalAnalysis(segments: snapshots) {
                result = r
            } else {
                reanalysisError = "Analysis returned no results."
                return
            }

            // Update meeting title if generated
            if let title = result.title, !title.isEmpty {
                meeting.title = title
            }

            // Persist new insight
            let insight = MeetingInsight(
                summary: result.summary,
                followUpQuestions: result.followUps,
                topics: result.topics
            )
            insight.meeting = meeting
            modelContext.insert(insight)

            // Replace action items (delete old, add new)
            for old in meeting.actionItems {
                modelContext.delete(old)
            }
            for parsed in result.actionItems {
                let item = ActionItem(text: parsed.text, assignee: parsed.assignee)
                item.meeting = meeting
                modelContext.insert(item)
            }

            try modelContext.save()
        } catch {
            reanalysisError = error.localizedDescription
            LogManager.send("Reanalysis failed: \(error.localizedDescription)", category: .ai, level: .error)
        }
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

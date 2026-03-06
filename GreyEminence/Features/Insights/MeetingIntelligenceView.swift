import SwiftUI

struct MeetingIntelligenceView: View {
    let meeting: Meeting

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

                if let insight = meeting.latestInsight {
                    AISummarySection(summary: insight.summary)
                    ActionItemsSection(items: meeting.actionItems)
                    FollowUpQuestionsSection(questions: insight.followUpQuestions)
                    KnowledgeLinksSection(topics: insight.topics)
                } else if meeting.isAnalyzing {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Analyzing meeting...")
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

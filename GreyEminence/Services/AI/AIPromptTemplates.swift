import Foundation

enum AIPromptTemplates {
    static let keychainKey = "claude_api_key"

    static var systemPrompt: String {
        """
        You are a meeting intelligence assistant. Your job is to analyze meeting transcripts \
        and produce structured insights.

        You MUST respond with ONLY valid JSON matching this exact schema — no prose, no markdown, \
        no explanation before or after:

        {
          "summary": "Bullet-point list summarizing the key points of the meeting so far. Each bullet should be a concise, standalone insight.",
          "action_items": [{"text": "description of action", "assignee": "person or null"}],
          "follow_ups": ["question that should be followed up on"],
          "topics": ["key topic discussed"]
        }

        Rules:
        - "summary" must be a bullet-point list (each bullet starting with "- "). Capture the overall \
        arc, not just the latest segment. Each bullet MUST describe a specific, concrete point with \
        a clear subject — what was discussed, decided, or proposed. Never include meta-observations \
        about the meeting itself (e.g. "Meeting is in early stages", "Participant mentioned wanting \
        to discuss something"). If there is not enough substantive content yet, return an empty string \
        for the summary rather than filler bullets.
        - "action_items" should only include concrete commitments or tasks, not vague statements. \
        Set "assignee" to the speaker's name if identifiable, otherwise null.
        - "follow_ups" are open questions or unresolved points that need attention after the meeting.
        - "topics" are the main subjects discussed, ordered by prominence.
        - If there is not enough content to produce meaningful insights, return empty arrays and \
        an empty string for the summary. Do not generate placeholder or filler text.
        - When updating a rolling analysis, ALWAYS preserve all previous action items, topics, \
        and follow-up questions. Your summary must be cumulative — include key information from \
        previous summaries plus new information. Never drop earlier insights unless they are \
        explicitly resolved or contradicted in the conversation.
        """
    }

    static func initialAnalysisPrompt(transcript: String) -> String {
        """
        Analyze the following meeting transcript and produce structured insights.

        TRANSCRIPT:
        \(transcript)
        """
    }

    static func rollingAnalysisPrompt(
        previousSummary: String,
        previousActionItems: [ParsedActionItem],
        previousFollowUps: [String],
        previousTopics: [String],
        newTranscript: String
    ) -> String {
        let actionItemsText = previousActionItems.isEmpty
            ? "(none)"
            : previousActionItems.enumerated().map { i, item in
                let assignee = item.assignee.map { " (assigned: \($0))" } ?? ""
                return "\(i + 1). \(item.text)\(assignee)"
            }.joined(separator: "\n")

        let followUpsText = previousFollowUps.isEmpty
            ? "(none)"
            : previousFollowUps.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")

        let topicsText = previousTopics.isEmpty
            ? "(none)"
            : previousTopics.joined(separator: ", ")

        return """
        Here is your complete previous analysis of this meeting:

        PREVIOUS SUMMARY:
        \(previousSummary)

        PREVIOUS ACTION ITEMS:
        \(actionItemsText)

        PREVIOUS FOLLOW-UP QUESTIONS:
        \(followUpsText)

        PREVIOUS TOPICS:
        \(topicsText)

        New transcript segments have been recorded since then. Extend your previous analysis \
        with the new content. Keep ALL existing action items, follow-ups, and topics. Add new \
        ones from the new transcript. Your summary should be cumulative — incorporate both \
        previous and new information.

        NEW TRANSCRIPT:
        \(newTranscript)
        """
    }

    static func finalCleanupPrompt(
        fullTranscript: String,
        currentSummary: String,
        currentActionItems: [ParsedActionItem],
        currentFollowUps: [String],
        currentTopics: [String]
    ) -> String {
        let actionItemsText = currentActionItems.isEmpty
            ? "(none)"
            : currentActionItems.enumerated().map { i, item in
                let assignee = item.assignee.map { " (assigned: \($0))" } ?? ""
                return "\(i + 1). \(item.text)\(assignee)"
            }.joined(separator: "\n")

        let followUpsText = currentFollowUps.isEmpty
            ? "(none)"
            : currentFollowUps.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")

        let topicsText = currentTopics.isEmpty
            ? "(none)"
            : currentTopics.joined(separator: ", ")

        return """
        The meeting has ended. Below is the full transcript and the insights accumulated \
        during live analysis. Produce a final, polished version of the insights.

        Your tasks:
        - Write a clean, comprehensive summary as a bullet-point list covering the entire meeting arc. \
        Each bullet must describe a specific, concrete point with a clear subject. Remove any \
        meta-observations about the meeting itself (e.g. "Meeting started with introductions").
        - Deduplicate action items — merge near-duplicates, remove redundant ones, \
        and keep the clearest phrasing.
        - Deduplicate follow-up questions — merge similar ones.
        - Consolidate topics — remove redundant or overly granular topics, order by prominence.
        - Correct any speaker attribution errors that are obvious from context.

        ACCUMULATED INSIGHTS FROM LIVE ANALYSIS:

        Summary:
        \(currentSummary)

        Action Items:
        \(actionItemsText)

        Follow-up Questions:
        \(followUpsText)

        Topics:
        \(topicsText)

        FULL TRANSCRIPT:
        \(fullTranscript)
        """
    }

    static func formatSegments(_ segments: [SegmentSnapshot]) -> String {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "[\($0.formattedTimestamp)] \($0.speaker.displayName): \($0.text)" }
            .joined(separator: "\n")
    }
}

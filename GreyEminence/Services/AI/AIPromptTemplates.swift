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
          "title": "Short descriptive meeting title (5-8 words, final analysis only, omit during rolling analysis)",
          "summary": [
            {
              "title": "Section title (2-5 words, sentence case, no period)",
              "intro": "One optional sentence framing this section. Omit key if not needed.",
              "points": [
                { "label": "Subject (1-4 words)", "detail": "1-3 sentence explanation of this point." }
              ]
            }
          ],
          "action_items": [{"text": "description of action", "assignee": "person or null"}],
          "follow_ups": ["question that should be followed up on"],
          "topics": ["Theme Topic", "specific-tool", "ACRONYM", "PersonName"]
        }

        Rules:
        - "summary" MUST be a JSON array of section objects as shown above. Return [] if there \
        is not enough substantive content yet — never return filler sections.
        - Group related points into coherent sections. Aim for 2-5 sections with 2-6 points each. \
        Each section covers one theme or topic area from the meeting.
        - Each point's "label" is the subject (1-4 words, title case). "detail" is 1-3 sentences \
        of specific, concrete information — what was discussed, decided, or proposed.
        - Never include meta-observations about the meeting itself (e.g. "Meeting covered several topics").
        - The "intro" field is optional — include it only when a sentence of context genuinely helps \
        frame the points below it. Otherwise omit the key entirely.
        - "action_items" should only include concrete commitments or tasks, not vague statements. \
        Set "assignee" to the speaker's name if identifiable, otherwise null.
        - "follow_ups" are open questions or unresolved points that need attention after the meeting.
        - "topics" should include TWO types, merged into one flat array ordered by prominence: \
        (1) Theme topics: broad subjects discussed (e.g. "System Design", "Code Review Process") \
        (2) Key terms: specific proper nouns, acronyms, tools, services, platforms, libraries, \
        or named systems mentioned (e.g. "OLP", "AIDC", "Kafka", "DynamoDB", "React"). \
        Extract ALL specific named entities — these are critical for cross-meeting knowledge mapping. \
        Prefer the canonical form (e.g. "DynamoDB" not "dynamo", "AIDC" not "aidc").
        - If there is not enough content to produce meaningful insights, return empty arrays and \
        [] for summary. Do not generate placeholder or filler text.
        - When updating a rolling analysis, ALWAYS preserve all previous action items, topics, \
        and follow-up questions. The PREVIOUS SUMMARY is a JSON array — parse it, keep all existing \
        sections and points, add new points to the relevant sections or add new sections for new topics. \
        Never drop earlier insights unless explicitly resolved or contradicted.
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

        PREVIOUS SUMMARY (JSON array of section objects — parse and extend this):
        \(previousSummary)

        PREVIOUS ACTION ITEMS:
        \(actionItemsText)

        PREVIOUS FOLLOW-UP QUESTIONS:
        \(followUpsText)

        PREVIOUS TOPICS:
        \(topicsText)

        New transcript segments have been recorded since then. Extend your previous analysis \
        with the new content. For the summary: keep all existing sections and points, add new \
        points to relevant existing sections, and add new sections for genuinely new topics. \
        Keep ALL existing action items, follow-ups, and topics. Add new ones from the new transcript. \
        For topics: extract both theme topics AND specific key terms (proper nouns, acronyms, \
        tools, services, platforms) mentioned in the new segments.

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
        - Generate a short, descriptive title for this meeting (5-8 words max, no quotes). \
        The title should capture the main topic or purpose, e.g. "Sprint Planning - Auth Service Redesign" \
        or "Q1 Budget Review with Finance". Return it in the "title" field.
        - Produce a clean, comprehensive summary as a JSON array of section objects (same schema \
        as always). The CURRENT SUMMARY below is already in this JSON format — refine it: \
        merge redundant points, tighten wording, reorder sections by importance, remove any \
        meta-observations. Cover the full meeting arc.
        - Deduplicate action items — merge near-duplicates, remove redundant ones, \
        and keep the clearest phrasing.
        - Deduplicate follow-up questions — merge similar ones.
        - Consolidate topics — remove exact duplicates and merge near-duplicates, but keep both \
        theme topics (broad subjects) AND key terms (specific names, acronyms, tools, services). \
        Order themes first by prominence, then key terms alphabetically. Preserve canonical forms \
        (e.g. "DynamoDB" not "dynamo").
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

    /// Enriched system prompt with meeting prep context for cross-meeting intelligence.
    static func systemPromptWithContext(prep: MeetingPrepContext?) -> String {
        guard let prep, !prep.isEmpty else { return systemPrompt }

        var contextBlock = "\n\nCONTEXT FROM PREVIOUS MEETINGS WITH THESE PARTICIPANTS:\n"

        if !prep.unresolvedItems.isEmpty {
            contextBlock += "\nUnresolved action items:\n"
            for item in prep.unresolvedItems {
                let assignee = item.assignee.map { " (assigned: \($0))" } ?? ""
                contextBlock += "- \(item.text)\(assignee) [\(item.daysSinceCreated) days old]\n"
            }
        }

        if !prep.followUps.isEmpty {
            contextBlock += "\nOpen follow-up questions:\n"
            for q in prep.followUps {
                contextBlock += "- \(q)\n"
            }
        }

        if !prep.previousTopics.isEmpty {
            contextBlock += "\nPreviously discussed topics: \(prep.previousTopics.joined(separator: ", "))\n"
        }

        contextBlock += """

        Watch for any of these items being discussed or resolved during the meeting. \
        If an unresolved item is addressed, note it in the summary. If an open question \
        is answered, remove it from follow_ups.
        """

        return systemPrompt + contextBlock
    }
}

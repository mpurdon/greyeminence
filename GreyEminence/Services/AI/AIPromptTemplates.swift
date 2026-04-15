import Foundation

enum AIPromptTemplates {
    static let keychainKey = "claude_api_key"

    /// Bumped whenever the built-in prompt text changes meaningfully. Persisted with
    /// MeetingInsight so we can tell which prompt generation produced a given result
    /// and offer "regenerate with newer prompt" UX later.
    static let promptVersion = "meeting.v1"

    // MARK: - Public accessors
    //
    // Each accessor consults `PromptStore` first. If the user has saved an override
    // via the developer settings, that text is used (with `{{placeholder}}` tokens
    // substituted). Otherwise the hardcoded default below is used. This gives us a
    // zero-disruption runtime editor while keeping defaults in source.

    static var systemPrompt: String {
        PromptStore.shared.get(.meetingSystem, default: defaultSystemPrompt)
    }

    static func initialAnalysisPrompt(transcript: String) -> String {
        let template = PromptStore.shared.get(.meetingInitial, default: defaultInitialAnalysisPrompt)
        return PromptStore.render(template, values: ["transcript": transcript])
    }

    static func rollingAnalysisPrompt(
        previousSummary: String,
        previousActionItems: [ParsedActionItem],
        previousFollowUps: [String],
        previousTopics: [String],
        newTranscript: String,
        suppressedActionItems: [String] = [],
        suppressedFollowUps: [String] = []
    ) -> String {
        let template = PromptStore.shared.get(.meetingRolling, default: defaultRollingAnalysisPrompt)
        return PromptStore.render(template, values: [
            "previousSummary": previousSummary,
            "previousActionItems": formatActionItems(previousActionItems),
            "previousFollowUps": formatNumberedList(previousFollowUps),
            "previousTopics": formatTopics(previousTopics),
            "newTranscript": newTranscript,
            "suppressionBlock": suppressionBlock(actionItems: suppressedActionItems, followUps: suppressedFollowUps),
        ])
    }

    static func finalCleanupPrompt(
        fullTranscript: String,
        currentSummary: String,
        currentActionItems: [ParsedActionItem],
        currentFollowUps: [String],
        currentTopics: [String],
        suppressedActionItems: [String] = [],
        suppressedFollowUps: [String] = []
    ) -> String {
        let template = PromptStore.shared.get(.meetingFinal, default: defaultFinalCleanupPrompt)
        return PromptStore.render(template, values: [
            "fullTranscript": fullTranscript,
            "currentSummary": currentSummary,
            "currentActionItems": formatActionItems(currentActionItems),
            "currentFollowUps": formatNumberedList(currentFollowUps),
            "currentTopics": formatTopics(currentTopics),
            "suppressionBlock": suppressionBlock(actionItems: suppressedActionItems, followUps: suppressedFollowUps),
        ])
    }

    /// Builds a "DO NOT RE-SUGGEST" block for prompts when the user has deleted
    /// action items or follow-ups on a prior run. Returns an empty string when
    /// both lists are empty so the template renders cleanly.
    private static func suppressionBlock(actionItems: [String], followUps: [String]) -> String {
        guard !actionItems.isEmpty || !followUps.isEmpty else { return "" }
        var block = "\n\nSUPPRESSED ITEMS — DO NOT RE-SUGGEST:\nThe user has explicitly deleted the following from a prior analysis. Do NOT include these (or semantically equivalent rewordings) in `action_items` or `follow_ups`.\n"
        if !actionItems.isEmpty {
            block += "\nSuppressed action items:\n"
            for item in actionItems {
                block += "- \(item)\n"
            }
        }
        if !followUps.isEmpty {
            block += "\nSuppressed follow-up questions:\n"
            for q in followUps {
                block += "- \(q)\n"
            }
        }
        return block
    }

    /// Return the built-in default for a key. Used by the editor to show a diff /
    /// preview against the user's override, and to power "Restore to default".
    static func defaultText(for key: PromptKey) -> String {
        switch key {
        case .meetingSystem:  defaultSystemPrompt
        case .meetingInitial: defaultInitialAnalysisPrompt
        case .meetingRolling: defaultRollingAnalysisPrompt
        case .meetingFinal:   defaultFinalCleanupPrompt
        }
    }

    // MARK: - Helpers

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

    private static func formatActionItems(_ items: [ParsedActionItem]) -> String {
        items.isEmpty
            ? "(none)"
            : items.enumerated().map { i, item in
                let assignee = item.assignee.map { " (assigned: \($0))" } ?? ""
                return "\(i + 1). \(item.text)\(assignee)"
            }.joined(separator: "\n")
    }

    private static func formatNumberedList(_ items: [String]) -> String {
        items.isEmpty
            ? "(none)"
            : items.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
    }

    private static func formatTopics(_ topics: [String]) -> String {
        topics.isEmpty ? "(none)" : topics.joined(separator: ", ")
    }

    // MARK: - Hardcoded defaults

    private static let defaultSystemPrompt: String = """
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

    private static let defaultInitialAnalysisPrompt: String = """
        Analyze the following meeting transcript and produce structured insights.

        TRANSCRIPT:
        {{transcript}}
        """

    private static let defaultRollingAnalysisPrompt: String = """
        Here is your complete previous analysis of this meeting:

        PREVIOUS SUMMARY (JSON array of section objects — parse and extend this):
        {{previousSummary}}

        PREVIOUS ACTION ITEMS:
        {{previousActionItems}}

        PREVIOUS FOLLOW-UP QUESTIONS:
        {{previousFollowUps}}

        PREVIOUS TOPICS:
        {{previousTopics}}

        New transcript segments have been recorded since then. Extend your previous analysis \
        with the new content. For the summary: keep all existing sections and points, add new \
        points to relevant existing sections, and add new sections for genuinely new topics. \
        Keep ALL existing action items, follow-ups, and topics. Add new ones from the new transcript. \
        For topics: extract both theme topics AND specific key terms (proper nouns, acronyms, \
        tools, services, platforms) mentioned in the new segments.

        NEW TRANSCRIPT:
        {{newTranscript}}
        {{suppressionBlock}}
        """

    private static let defaultFinalCleanupPrompt: String = """
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
        {{currentSummary}}

        Action Items:
        {{currentActionItems}}

        Follow-up Questions:
        {{currentFollowUps}}

        Topics:
        {{currentTopics}}

        FULL TRANSCRIPT:
        {{fullTranscript}}
        {{suppressionBlock}}
        """
}

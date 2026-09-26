import Foundation

enum AIPromptTemplates {
    static let keychainKey = "claude_api_key"

    /// Bumped whenever the built-in prompt text changes meaningfully. Persisted with
    /// MeetingInsight so we can tell which prompt generation produced a given result
    /// and offer "regenerate with newer prompt" UX later.
    static let promptVersion = "meeting.v6"

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
        suppressedFollowUps: [String] = [],
        relatedContext: String? = nil
    ) -> String {
        let template = PromptStore.shared.get(.meetingFinal, default: defaultFinalCleanupPrompt)
        return PromptStore.render(template, values: [
            "fullTranscript": fullTranscript,
            "currentSummary": currentSummary,
            "currentActionItems": formatActionItems(currentActionItems),
            "currentFollowUps": formatNumberedList(currentFollowUps),
            "currentTopics": formatTopics(currentTopics),
            "suppressionBlock": suppressionBlock(actionItems: suppressedActionItems, followUps: suppressedFollowUps),
            "relatedContext": relatedContextBlock(relatedContext),
        ])
    }

    /// Wraps retrieved snippets from other meetings in instructions that scope
    /// them to blind-spot detection only. Empty string when there's nothing —
    /// the template renders cleanly without the block.
    static func relatedContextBlock(_ snippets: String?) -> String {
        guard let snippets, !snippets.isEmpty else { return "" }
        return """


        RELATED DISCUSSIONS FROM OTHER MEETINGS:
        The snippets below come from OTHER meetings' transcripts — none of this was said \
        in this meeting. Use them ONLY to find blind spots: if they raise concerns, \
        constraints, stakeholders, decisions, or topics relevant to this meeting's purpose \
        that this meeting never touched, turn those into follow_ups. Do NOT import them \
        into the summary, action items, or topics.

        \(snippets)
        """
    }

    /// Wraps screen-share observations in instructions with the opposite
    /// fencing from prep context: this content IS part of the meeting and
    /// should shape the output — it just must never be attributed as speech.
    /// Empty string when there's nothing.
    static func screenObservationBlock(_ observations: String?) -> String {
        guard let observations, !observations.isEmpty else { return "" }
        return """


        SCREEN SHARE CONTENT (visible on screen, not spoken):
        The participants shared a screen during this meeting. The lines below are \
        observations of that screen at the given transcript timestamps. This content \
        IS part of the meeting — use it to inform the summary, topics, follow-up \
        questions, and action items — but never attribute it as something a person \
        said, and never quote it as speech.

        \(observations)
        """
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
        case .screenSystem:   defaultScreenSystemPrompt
        case .screenAnalysis: defaultScreenAnalysisPrompt
        case .screenSessionSynthesis: defaultSessionSynthesisPrompt
        case .reportSystem:   defaultReportSystemPrompt
        case .reportFigureAnchors: defaultFigureAnchorPrompt
        case .transcriptCorrectionSystem: defaultTranscriptCorrectionSystemPrompt
        case .transcriptCorrection: defaultTranscriptCorrectionPrompt
        case .taskTriageSystem: defaultTaskTriageSystemPrompt
        case .taskTriage: defaultTaskTriagePrompt
        case .refinementSystem: defaultRefinementSystemPrompt
        case .refinementReport: defaultRefinementReportPrompt
        case .refinementClassify: defaultRefinementClassifyPrompt
        case .refinementSpec: defaultRefinementSpecPrompt
        case .topicClassify: defaultTopicClassifyPrompt
        }
    }

    // MARK: - Transcript correction

    static var transcriptCorrectionSystemPrompt: String {
        PromptStore.shared.get(.transcriptCorrectionSystem, default: defaultTranscriptCorrectionSystemPrompt)
    }

    static func transcriptCorrectionPrompt(context: String, lines: String) -> String {
        let template = PromptStore.shared.get(.transcriptCorrection, default: defaultTranscriptCorrectionPrompt)
        return PromptStore.render(template, values: ["context": context, "lines": lines])
    }

    static let defaultTranscriptCorrectionSystemPrompt = """
        You repair speech-recognition errors in a meeting transcript. The \
        recogniser sometimes writes a common word or phrase that sounds like \
        what was said but makes no sense where it sits — "suffering" for \
        "software engineering", a product name turned into an ordinary word, \
        a colleague's name spelt as something else. You fix only those. You \
        never rephrase, tidy grammar, remove filler, or touch a line you are \
        not sure about. You MUST respond with ONLY valid JSON matching the \
        schema in the user message — no prose, no markdown.
        """

    private static let defaultTranscriptCorrectionPrompt: String = """
        {{context}}

        Below is the transcript, one line per turn. Lines the recogniser was \
        unsure about are marked (low confidence); look hardest there, but a \
        confident line can still be wrong when it makes no sense in context.

        Return JSON of exactly this shape, listing ONLY lines that need a fix, \
        each with the complete corrected text of that line:
        {"corrections":[{"line":"L12","text":"the full corrected line"}]}
        An empty list is the right answer for a transcript with nothing to fix.

        Rules:
        - Change a word only when what is written is a mis-hearing: it sounds \
        like the intended word and does not fit the conversation, the \
        participants, the terms, or the topics given above.
        - Keep everything else in the line exactly as it is — wording, filler, \
        punctuation, the speaker's grammar. A fix replaces a few words, never \
        rewrites a sentence.
        - Prefer the names, terms and topics listed above when they are the \
        plausible intended words — but only where they genuinely fit. A term's \
        kind says where it can go: a person fits "X said", a document or \
        record fits "the X shows", a system fits "migrated from X". Do not put \
        a term into a slot its kind does not fit.
        - When a word sounds like both a participant's name and some other \
        name, choose the participant. People on the call are mentioned far \
        more often than people who are not.
        - Never introduce a term listed as rarely mentioned unless the \
        surrounding sentence plainly refers to it. A rare term is not a \
        candidate for a word you cannot place.
        - When unsure, leave the line alone.

        TRANSCRIPT
        {{lines}}
        """

    // MARK: - Screen-frame analysis

    static var screenSystemPrompt: String {
        PromptStore.shared.get(.screenSystem, default: defaultScreenSystemPrompt)
    }

    static func screenAnalysisPrompt(
        frameCount: Int,
        frameManifest: String,
        recentTopics: [String],
        previousObservation: String?
    ) -> String {
        let template = PromptStore.shared.get(.screenAnalysis, default: defaultScreenAnalysisPrompt)
        return PromptStore.render(template, values: [
            "frameCount": "\(frameCount)",
            "frameManifest": frameManifest,
            "recentTopics": recentTopics.isEmpty ? "(none yet)" : recentTopics.joined(separator: ", "),
            "previousObservation": previousObservation ?? "(none — this is the first analyzed batch)",
        ])
    }

    // MARK: - Session synthesis

    static let sessionSynthesisSystemPrompt = """
        You are a meeting intelligence assistant. You fuse what was shown on \
        a shared screen with what was said while it was on screen, producing \
        a recap grounded strictly in the material you are given. You MUST \
        respond with ONLY valid JSON matching the schema in the user message — \
        no prose, no markdown, no explanation before or after.
        """

    static func sessionSynthesisPrompt(
        windowTitle: String?,
        sessionSpan: String,
        frameDescriptions: String,
        transcriptExcerpt: String
    ) -> String {
        let template = PromptStore.shared.get(.screenSessionSynthesis, default: defaultSessionSynthesisPrompt)
        return PromptStore.render(template, values: [
            "windowTitle": windowTitle?.isEmpty == false ? windowTitle! : "(untitled window)",
            "sessionSpan": sessionSpan,
            "frameDescriptions": frameDescriptions,
            "transcriptExcerpt": transcriptExcerpt,
        ])
    }

    // MARK: - Helpers

    static func formatSegments(_ segments: [SegmentSnapshot]) -> String {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "[\($0.formattedTimestamp)] \($0.speaker.displayName): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Enriched system prompt with the meeting roster and prep context for
    /// cross-meeting intelligence.
    static func systemPromptWithContext(prep: MeetingPrepContext?, roster: MeetingRoster? = nil) -> String {
        let base = systemPrompt + rosterBlock(roster)
        guard let prep, prep.hasContent else { return base }

        var contextBlock = "\n\nCONTEXT FROM PREVIOUS OCCURRENCES OF THIS RECURRING MEETING:\n"

        if !prep.unresolvedItems.isEmpty {
            contextBlock += "\nUnresolved action items:\n"
            for item in prep.unresolvedItems {
                let assignee = item.assignee.map { " (assigned: \($0))" } ?? ""
                contextBlock += "- \(item.text)\(assignee) [\(item.daysSinceCreated) days old]\n"
            }
        }

        if !prep.followUps.isEmpty {
            contextBlock += "\nFollow-up questions left open by prior occurrences:\n"
            for q in prep.followUps {
                contextBlock += "- \(q)\n"
            }
        }

        if !prep.previousTopics.isEmpty {
            contextBlock += "\nTopics discussed in prior occurrences: \(prep.previousTopics.joined(separator: ", "))\n"
        }

        contextBlock += """

        NONE of the above was said in the current meeting — it is background carried \
        over from prior occurrences, for reference only. Do NOT copy these questions \
        into "follow_ups", these topics into "topics", or these items into \
        "action_items": everything you output must be grounded in what is actually \
        said in the current transcript. Use this background only to recognize \
        continuity — if the discussion resolves an unresolved item or answers an open \
        question, note that in the summary.
        """

        return base + contextBlock
    }

    /// Participant block appended to the system prompt when the attendee list
    /// is known beyond just the user. Anchors "assignee" to real names so
    /// items land on the correct attendee, and lets the model apply the
    /// ownership rules (mine / unowned / 1:1 exception) reliably.
    static func rosterBlock(_ roster: MeetingRoster?) -> String {
        guard let roster, !roster.otherAttendees.isEmpty else { return "" }
        let user = roster.myName.map { "\($0) — they appear in the transcript as \"Me\"" }
            ?? "the person appearing in the transcript as \"Me\""
        return """


        MEETING PARTICIPANTS:
        The tool user is \(user). Other attendees: \(roster.otherAttendees.joined(separator: ", ")).
        When setting "assignee", use exactly "Me" for the tool user or one of the attendee \
        names above — match the person the transcript actually refers to; never invent a \
        name that isn't listed.
        """
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
          "action_items": [{"text": "description of action", "assignee": "person or null", "source_quote": "verbatim phrase from the transcript that triggered this item"}],
          "follow_ups": ["question that should be followed up on"],
          "topics": ["Theme Topic", "specific-tool", "ACRONYM", "PersonName"],
          "refinement": {"likelihood": 0.0, "features": ["Feature name"]}
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
        - "action_items" exist for ONE person: the tool user (the "Me" speaker in the \
        transcript). Include only (1) tasks the user personally committed to or was asked \
        to take on, and (2) tasks nobody clearly owns. Do NOT include tasks another \
        attendee clearly owns — the summary already captures what other people are doing. \
        EXCEPTION — 1:1 meetings: when exactly two people are in the meeting (the user and \
        one other person), include the other person's commitments too, and if a task is \
        definitely not the user's, set "assignee" to the other participant's name rather \
        than leaving it unowned. \
        Be selective: only concrete, deliberate commitments — never vague intentions, \
        hypotheticals, or process observations. A typical 30-minute meeting yields 3-6 \
        genuine action items; more than 8 means you are over-extracting — merge related \
        tasks and drop the marginal ones. \
        Set "assignee" to "Me" when the task is the user's, the other participant's name \
        under the 1:1 exception, or null when ownership is genuinely unclear. \
        Set "source_quote" to a short verbatim snippet (one sentence, 5-25 words) copied from \
        the transcript that triggered this action — the exact words a speaker said, not your \
        paraphrase. This anchors the task to a specific moment in the conversation. Pick the \
        single most direct sentence; do not concatenate multiple turns.
        - "follow_ups" are BLIND SPOTS: specific questions about things that were NOT \
        discussed in the meeting but are likely relevant to its purpose — the questions \
        nobody thought to ask. Look for: risks or failure modes nobody raised, stakeholders \
        or perspectives that were missing from the conversation, alternatives that went \
        unexamined, dependencies or second-order consequences of the decisions made, and \
        (when RELATED DISCUSSIONS from other meetings are provided) relevant prior context \
        this meeting overlooked. \
        Hard rules: a follow-up must NOT be answerable from the transcript — if the meeting \
        discussed it, even partially, it does not belong here. DO NOT restate a summary \
        point or an action item as a question — if a task is "Investigate X", do not emit \
        "What is X?" or "Who will investigate X?". DO NOT ask for status updates on things \
        already assigned. Avoid generic questions that could be asked of any meeting \
        ("What is the timeline?") — every question must be anchored in this meeting's \
        specific content. Quality over quantity: 2-5 sharp questions beat a long list. \
        If nothing qualifies, return an empty array.
        - "topics" should include TWO types, merged into one flat array ordered by prominence: \
        (1) Theme topics: broad subjects discussed (e.g. "System Design", "Code Review Process") \
        (2) Key terms: specific proper nouns, acronyms, tools, services, platforms, libraries, \
        or named systems mentioned (e.g. "OLP", "AIDC", "Kafka", "DynamoDB", "React"). \
        Extract ALL specific named entities — these are critical for cross-meeting knowledge mapping. \
        Prefer the canonical form (e.g. "DynamoDB" not "dynamo", "AIDC" not "aidc").
        - "refinement" is for the final analysis only — omit it during initial and rolling \
        analysis. "likelihood" (0.0-1.0) is how likely it is that a substantial part of \
        this meeting was spent refining a software feature: working out its intended \
        behaviour, acceptance criteria, scope, edge cases or design before or during \
        implementation (backlog refinement, grooming, a spec or design walkthrough, a \
        feature kickoff). High (0.7+) only when the group actually worked through what \
        a feature should do. Low for status updates, standups, incident reviews, 1:1s, \
        sales or support calls, and meetings that only mention a feature in passing. \
        "features" names each distinct feature the group refined, 2-6 words each, the one \
        that got the most time first, at most 4 — and [] when likelihood is below 0.5. \
        \(refinementFeatureRules)
        - If there is not enough content to produce meaningful insights, return empty arrays and \
        [] for summary. Do not generate placeholder or filler text.
        - When updating a rolling analysis, ALWAYS preserve all previous action items, topics, \
        and follow-up questions. The PREVIOUS SUMMARY is a JSON array — parse it, keep all existing \
        sections and points, add new points to the relevant sections or add new sections for new topics. \
        Never drop earlier insights unless explicitly resolved, contradicted, or revealed \
        to be owned by another attendee (per the action_items ownership rules).
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
        and keep the clearest phrasing. Re-check ownership against the full transcript: \
        drop any item another attendee clearly owns (unless the two-person exception \
        applies) and fix assignees that don't match what was actually said.
        - Re-derive the follow-up questions against the FULL transcript. Drop any \
        accumulated question the transcript actually answers or that overlaps an action \
        item, merge near-duplicates, and add new blind-spot questions now visible from \
        the complete meeting arc (and from RELATED DISCUSSIONS, when provided).
        - Consolidate topics — remove exact duplicates and merge near-duplicates, but keep both \
        theme topics (broad subjects) AND key terms (specific names, acronyms, tools, services). \
        Order themes first by prominence, then key terms alphabetically. Preserve canonical forms \
        (e.g. "DynamoDB" not "dynamo").
        - Correct any speaker attribution errors that are obvious from context.
        - Assess whether this meeting refined a software feature and return the \
        "refinement" object.

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
        {{relatedContext}}
        {{suppressionBlock}}
        """

    private static let defaultScreenSystemPrompt: String = """
        You are analyzing screenshots of content shared on screen during a live \
        meeting (slides, code, diagrams, dashboards, documents). For each image you \
        receive, produce a DETAILED description — thorough enough that a meeting \
        assistant that never sees the image can reconstruct what was shown and \
        weave it into the meeting's story.

        You MUST respond with ONLY valid JSON matching this exact schema — no prose, \
        no markdown, no explanation before or after:

        {
          "frames": [
            {
              "index": 0,
              "observation": "100-250 words: the shared CONTENT itself — substantive text, data, and values transcribed verbatim — plus what is new or different versus the previous frame",
              "content_type": "slide|code|diagram|dashboard|document|terminal|video|other",
              "key_entities": ["specific named things visible: systems, projects, tickets, people, metrics"],
              "notable_text": "short verbatim text that carries meaning beyond the OCR excerpt you were given, or null"
            }
          ]
        }

        Rules:
        - One entry per image, "index" matching the order the images were provided.
        - Each observation is 100-250 words about the CONTENT being shared — \
        the document, data, code, or slide. Transcribe the substance: real \
        numbers, table rows, chart axes and values, code identifiers and \
        signatures, dates, names, ticket IDs, metric readings — verbatim where \
        the values carry meaning. Never compress legible data into vague \
        phrases ("some metrics", "a list of items").
        - NEVER describe application chrome: menus, toolbars, side panels, \
        tab bars, viewer controls, window furniture. "The left panel shows an \
        'All Tools' menu" is worthless — that is the app, not what's being \
        shared. Name the application in at most a few words, and only when it \
        genuinely aids context ("a PDF of the Q3 contract").
        - When a previous-frame description is provided, or multiple frames \
        are in this batch, describe only what is NEW or DIFFERENT in the \
        content ("error rate now 4.1%, up from 2.3%"; "scrolled to the \
        Codesheets table: …"). Never say things are "the same" or re-describe \
        unchanged material — spend the words on what changed.
        - Never invent content you cannot actually read — describe partial \
        legibility honestly ("y-axis labels too small to read").
        - Extract key_entities in canonical form; they feed cross-meeting search.
        - If an image is unreadable or blank, say so in the observation and use \
        content_type "other".
        """

    private static let defaultScreenAnalysisPrompt: String = """
        {{frameCount}} screenshot(s) captured from a screen share during the meeting, \
        in chronological order. For context, the meeting's topics so far: {{recentTopics}}

        The most recently analyzed frame (immediately before this batch) was \
        described as: {{previousObservation}}

        For each image, on-device OCR extracted the following text (may be partial \
        or noisy — trust the image over the OCR):

        {{frameManifest}}

        Analyze each image and respond with the JSON schema from your instructions.
        """

    private static let defaultSessionSynthesisPrompt: String = """
        A screen-share session just ended during a meeting. \
        Window: "{{windowTitle}}", shown {{sessionSpan}} (elapsed meeting time).

        DETAILED FRAME DESCRIPTIONS (chronological, from screenshots of the share):
        {{frameDescriptions}}

        TRANSCRIPT AROUND THE SESSION (from 30s before it started to 30s after it ended):
        {{transcriptExcerpt}}

        Write a recap that fuses what was SHOWN with what was SAID — the story \
        of this share session as part of the meeting.

        Respond with ONLY valid JSON matching this exact schema:

        {
          "narrative": "One 120-250 word paragraph: what was presented, how it evolved across the session, and how the conversation engaged with it. Weave spoken reactions and decisions together with the on-screen content. Preserve concrete values (numbers, dates, names, identifiers) from the frames.",
          "key_moments": [{"time": "m:ss", "label": "5-12 words: what happened at this moment"}],
          "entities": ["canonical named things: systems, projects, tickets, people, metrics"]
        }

        Rules:
        - Ground every claim in the frames or the transcript above — never invent \
        content, and never present speculation as fact.
        - 3-8 key_moments. Every "time" must be a real timestamp copied from a \
        frame or transcript line above. Prefer moments where the screen content \
        changed or the discussion pivoted.
        - If the transcript is empty or unrelated, recap the screen content alone \
        and say the room did not discuss it.
        """


    // MARK: - Report figure anchoring

    static var reportSystemPrompt: String {
        PromptStore.shared.get(.reportSystem, default: defaultReportSystemPrompt)
    }

    static func figureAnchorPrompt(sectionOutline: String, frameCatalogue: String) -> String {
        let template = PromptStore.shared.get(.reportFigureAnchors, default: defaultFigureAnchorPrompt)
        return PromptStore.render(template, values: [
            "sectionOutline": sectionOutline,
            "frameCatalogue": frameCatalogue,
        ])
    }

    static let defaultReportSystemPrompt = """
        You place captured screenshots into a written meeting report. A \
        screenshot belongs beside the section whose content was being \
        discussed while it was on screen, and it earns its place by giving \
        the reader context for what that section says. You MUST respond with \
        ONLY valid JSON matching the schema in the user message — no prose, \
        no markdown, no explanation before or after.
        """

    private static let defaultFigureAnchorPrompt: String = """
        Below are the sections of a written meeting summary, and the \
        screenshots captured from the shared screen during that meeting. Each \
        screenshot comes with a description of what was on screen and an \
        excerpt of what was being said around the moment it was captured.

        Your job is to match screenshots to the sections they support, using \
        the conversation at that point to decide where each one belongs. Read \
        the excerpt: the section that summarises that part of the discussion \
        is the section the screenshot goes with. Then say, in one line each, \
        what the screenshot shows and what it adds for the reader.

        SECTIONS
        {{sectionOutline}}

        CAPTURED SCREENSHOTS
        {{frameCatalogue}}

        Return JSON of exactly this shape:
        {"figures":[{"frame":"F3","section":"S2","caption":"one short line"}]}

        Choosing:
        - Match on the conversation first. The description tells you what was \
        on screen; the excerpt tells you what it was being used for. A \
        screenshot belongs to the section whose points were being discussed \
        in its excerpt, not merely to a section from a similar moment.
        - Include a screenshot when it gives context for a section's points — \
        the diagram being walked through, the document being reviewed, the \
        numbers being debated. When a section's discussion happened with \
        material on screen, that material usually belongs beside it. Leave \
        out only screenshots that add nothing the words already say.
        - NEVER include one showing only the video call — participant tiles, \
        a gallery of faces, a speaker's camera, an empty meeting window.
        - When several screenshots show the same thing, keep the clearest \
        one. At most 3 per section.
        - Omit screenshots you do not choose. They are not printed. Do not \
        include them with a null section.

        Captions — the caption is the tie between picture and summary:
        - Say what the screenshot shows AND what it establishes for the \
        section. "The RDL suggestions under debate: two AI-proposed Joint \
        Pain entries, both at 10%" — the reader immediately sees why it is \
        on the page.
        - Use the real nouns from the description: the tool, the screen, the \
        field, the value. Never "a screen from the design tool".
        - NEVER describe the meeting or the call — "Zoom call in progress", \
        "during the design discussion". The reader can see it is a screen \
        share. The window, video tiles and toolbar are chrome; caption the \
        content inside them.
        - Under 20 words. Do not begin with "Screenshot of", "This shows", \
        "A view of", "The user is".
        - Use only what the description and excerpt state. Invent nothing.
        - Use only the S and F identifiers given above.
        """

    // MARK: - Task tidy-up

    static var taskTriageSystemPrompt: String {
        PromptStore.shared.get(.taskTriageSystem, default: defaultTaskTriageSystemPrompt)
    }

    static func taskTriagePrompt(today: String, pendingTasks: String, completedTasks: String) -> String {
        let template = PromptStore.shared.get(.taskTriage, default: defaultTaskTriagePrompt)
        return PromptStore.render(template, values: [
            "today": today,
            "pendingTasks": pendingTasks,
            "completedTasks": completedTasks,
        ])
    }

    static let defaultTaskTriageSystemPrompt = """
        You keep one person's task list honest. The tasks were extracted \
        automatically from meeting transcripts, so the list accumulates \
        near-duplicates, things that were never really tasks, and items \
        nobody could act on. You rate each task's importance, fold \
        duplicates together, and drop what does not belong. You MUST respond \
        with ONLY valid JSON matching the schema in the user message — no \
        prose, no markdown, no explanation before or after.
        """

    private static let defaultTaskTriagePrompt: String = """
        Today is {{today}}. Below is a person's open task list, extracted \
        from meeting transcripts. Each task has an identifier, its text, who \
        it is assigned to, the meeting it came from, and its age.

        OPEN TASKS
        {{pendingTasks}}

        RECENTLY COMPLETED (for reference — do not rate these)
        {{completedTasks}}

        Decide, for every open task, exactly one of:
        - "keep" with a "priority" of "high", "medium" or "low".
        - "duplicate" with "of" naming the open task it repeats (or the \
        completed task it was already done as). The named task is kept; this \
        one is folded into it.
        - "remove" with a short "reason" — the item is not a task.

        Return JSON of exactly this shape:
        {"decisions":[{"id":"T1","action":"keep","priority":"high"},{"id":"T2","action":"duplicate","of":"T1"},{"id":"T3","action":"remove","reason":"not a task"}]}

        Rating importance:
        - High: a commitment someone else is waiting on, a deadline that is \
        near or has passed, or something that blocks other work — a customer \
        deliverable, a decision a team is blocked on, a promise made to a \
        named person.
        - Medium: real work with no one waiting on it right now — follow-ups, \
        reviews, things to draft or look into.
        - Low: nice-to-haves, vague intentions, "we should at some point".
        - Age matters both ways: an old high-stakes task is still high; an \
        old vague one is low.

        Folding duplicates:
        - Two tasks are duplicates when doing one would do the other — the \
        same deliverable phrased differently, or the same request repeated \
        in a later meeting. Different meetings are the usual source.
        - Keep the more specific wording (the one naming the person, the \
        artifact, the date). If they are equally specific, keep the newer.
        - Two tasks about the same subject that ask for different things \
        are NOT duplicates. "Send the deck to Priya" and "Get Priya's \
        feedback on the deck" are two tasks.
        - "of" must name a task that is itself kept, or a completed task. \
        Never chain duplicates.

        Removing:
        - Remove what is not a task: a topic of discussion, a fact, a \
        question with no work behind it, a fragment with no verb, an agenda \
        line, something the transcript shows was said hypothetically.
        - Remove tasks that cannot be acted on because they have no \
        content — "follow up", "look into it", "the thing from Tuesday" \
        with nothing else to go on.
        - Do NOT remove a task merely because it is old, unassigned, small, \
        or assigned to someone other than the list's owner. When in doubt, \
        keep it and rate it low.

        Use only the T and C identifiers given above. Every open task must \
        appear exactly once.
        """

    // MARK: - Refinement report

    static var refinementSystemPrompt: String {
        PromptStore.shared.get(.refinementSystem, default: defaultRefinementSystemPrompt)
    }

    static func refinementReportPrompt(
        meetingTitle: String,
        meetingDate: String,
        participants: String,
        screenContext: String,
        focus: String = "",
        transcript: String
    ) -> String {
        let template = PromptStore.shared.get(.refinementReport, default: defaultRefinementReportPrompt)
        return PromptStore.render(template, values: [
            "meetingTitle": meetingTitle,
            "meetingDate": meetingDate,
            "participants": participants,
            "screenContext": screenContext,
            "focus": focus,
            "transcript": transcript,
        ])
    }

    static let defaultRefinementSystemPrompt = """
        You analyze transcripts of meetings in which people refine a software \
        feature, and reconstruct the specification the discussion actually \
        arrived at. You separate what was said from what you infer, and you \
        never invent a rationale the transcript does not contain. You MUST \
        respond with ONLY valid JSON matching the schema in the user message \
        — no prose, no markdown, no explanation before or after.
        """

    /// Adapted from a review prompt for software-development agent sessions:
    /// the sections and rules are the same, the evidence is a meeting
    /// transcript instead of an engineer–agent exchange.
    static let defaultRefinementReportPrompt: String = """
        You are analyzing the transcript of a meeting in which the \
        participants refined a software feature.

        Your job is NOT to summarize the conversation.

        Reconstruct the effective specification that emerged while the \
        participants worked through the feature.

        The original ticket/spec may be incomplete or may differ from what \
        the meeting settled on. Pay particular attention to decisions made \
        during the discussion that were never explicitly written into the \
        original requirements.

        MEETING
        Title: {{meetingTitle}}
        Date: {{meetingDate}}
        Participants: {{participants}}
        {{focus}}{{screenContext}}
        TRANSCRIPT
        Each line is [timestamp] speaker: words. The transcript is automatic: \
        expect mis-heard words, and speaker labels that are sometimes wrong \
        or generic ("Speaker 2"). Attribute a statement to a named person \
        only when the transcript makes it clear; otherwise say "a \
        participant". Cite timestamps like [12:04] for key evidence.

        {{transcript}}

        Produce the analysis below as JSON of exactly this shape:

        {
          "is_refinement": true,
          "intent": "1-3 sentences",
          "acceptance_criteria": [
            {"text": "observable condition", "basis": "explicit | emergent | inferred", \
        "confidence": "low | medium | high (inferred only, else null)", \
        "evidence": "what in the transcript supports it — a short quote or paraphrase", \
        "citations": ["mm:ss", "mm:ss-mm:ss"]}
          ],
          "decisions": [
            {"decision": "...", "category": "short tag, e.g. design, validation, scope", \
        "reason": "reason/evidence, or null", "alternatives": "alternatives considered, or null", \
        "effect": "effect on behavior", "basis": "explicit | inferred", \
        "citations": ["mm:ss"]}
          ],
          "rejected_approaches": [{"approach": "...", "reason": "why, or null", "citations": ["mm:ss"]}],
          "constraints": [{"text": "...", "source": "where it came from, or null", "citations": ["mm:ss"]}],
          "reviewer_notes": ["..."],
          "open_questions": [{"question": "...", "owner": "who was to resolve it, or null", "citations": ["mm:ss"]}]
        }

        What each field holds:

        intent — the outcome the participants appear to have been trying to \
        achieve, in 1-3 sentences. Do not describe implementation details \
        unless they are necessary to explain the intent.

        acceptance_criteria — observable conditions the finished feature is \
        expected to satisfy. Label each:
        - explicit — directly stated by a participant or the source requirements
        - emergent — established during the meeting through discussion, a \
        worked example, an objection, or a decision
        - inferred — strongly suggested by the discussion but never clearly \
        stated. For these, explain the evidence and give a confidence.

        decisions — consequential decisions such as architecture or design \
        choices, existing utilities/patterns chosen instead of new code, data \
        types or representations, validation behavior, authentication/\
        authorization assumptions, error handling, API behavior, backwards \
        compatibility, performance considerations, testing strategy, scope \
        deliberately excluded, and refactors to make along the way. Do not \
        invent a rationale when the transcript doesn't contain one — use null.

        rejected_approaches — approaches proposed or considered and then \
        abandoned, with why if the transcript says.

        constraints — constraints that materially shaped the feature but may \
        not have been in the original request: existing repository \
        conventions, library limitations, API behavior, database constraints, \
        compatibility requirements, production assumptions, deadlines, team \
        or ownership boundaries.

        reviewer_notes — imagine someone who was not in this meeting \
        implements this feature, or reviews the resulting pull request, with \
        only the ticket and the diff in hand. What from this meeting would \
        help them do it correctly that they would NOT easily learn from the \
        ticket or the code? Only items that materially affect correctness, \
        intent, risk, or scope.

        open_questions — decisions that appear unresolved, assumptions never \
        verified, and places where the work may proceed without enough \
        information.

        citations — on every item that has them: the transcript timestamps \
        where the evidence is, copied from the [m:ss] stamps on the lines \
        above. A single line as "7:52"; a stretch of discussion as \
        "7:01-7:10". Cite the lines that actually support the item, most \
        direct first, at most four. Use [] when the support is not in the \
        transcript (e.g. only on the shared screen) — never invent a \
        timestamp.

        IMPORTANT RULES:
        - Separate evidence from inference.
        - Do not treat everything a participant suggested as a decision. A \
        decision counts only if it changed the direction of the work or was \
        accepted by the group.
        - Ideas floated and then dropped are not acceptance criteria.
        - Do not manufacture reasons that are absent from the transcript.
        - Prefer behavioral criteria over implementation details.
        - Surface contradictions between the original request and what the \
        meeting settled on — as a decision, a reviewer note, or an open question.
        - Use an empty array when a section has nothing to report. Never pad.
        - If the meeting was not about refining a feature, set \
        "is_refinement" to false, say what it was about in "intent", and \
        leave every array empty.
        """

    // MARK: - Topic categories

    // MARK: - Spec from the reviewed rationale

    static func refinementSpecPrompt(feature: String, rationale: String) -> String {
        let template = PromptStore.shared.get(.refinementSpec, default: defaultRefinementSpecPrompt)
        return PromptStore.render(template, values: ["feature": feature, "rationale": rationale])
    }

    /// The spec is written from the rationale as the reviewer left it, not
    /// from the transcript: their priorities, answers and wording are the
    /// point, and anything they left out must stay out.
    static let defaultRefinementSpecPrompt: String = """
        A team refined the feature "{{feature}}" in a meeting. Its rationale \
        was reconstructed from the transcript and then reviewed by a person: \
        they set priorities (Must / Should / Could / Won't) on acceptance \
        criteria and constraints, rewrote items, answered open questions, \
        added items and notes, and removed what didn't belong.

        REVIEWED RATIONALE
        {{rationale}}

        Write the effective specification — what was decided, short enough \
        to put directly in a ticket or pull request — as JSON of exactly \
        this shape:

        {
          "intent": "1-2 sentences",
          "acceptance_criteria": ["[Must] observable condition", "..."],
          "decisions": ["..."],
          "constraints": ["..."],
          "open_questions": ["..."]
        }

        Rules:
        - The review is authoritative. Use the reviewer's wording where they \
        rewrote an item; follow their notes; never bring back anything that \
        isn't in the rationale above.
        - Keep each criterion's and constraint's priority as a prefix: \
        "[Must] …". Order criteria Must, Should, Could. A Won't item goes in \
        constraints as an explicit non-goal ("Out of scope: …").
        - A resolved question is settled: fold its answer into the criteria, \
        decisions or constraints it affects, and leave it out of \
        open_questions. Only unresolved questions remain there.
        - One line per bullet, behavioral rather than implementation detail. \
        Merge duplicates; don't add anything new.
        - Use an empty array for a section with nothing in it.
        """

    static func topicClassifyPrompt(people: String, topics: String) -> String {
        let template = PromptStore.shared.get(.topicClassify, default: defaultTopicClassifyPrompt)
        return PromptStore.render(template, values: ["people": people, "topics": topics])
    }

    static let topicClassifySystemPrompt = """
        You sort topics from meeting notes into kinds and spot other names \
        for the same thing. You MUST respond with ONLY valid JSON matching \
        the schema in the user message — no prose, no markdown, no \
        explanation before or after.
        """

    /// One pass per distinct topic, library-wide. Each topic comes with a
    /// meeting it appeared in and its neighbours there, because a bare name
    /// ("Milo", "Cadence") can be a person, a service or a project.
    private static let defaultTopicClassifyPrompt: String = """
        Below are topics taken from a company's meeting notes: themes and \
        key terms (names, acronyms, tools, systems). Each has an identifier, \
        and a meeting it came up in with the topics it appeared alongside.

        PEOPLE KNOWN TO BE IN THESE MEETINGS
        {{people}}

        TOPICS
        {{topics}}

        For every topic, give its "kind":
        - person: an individual, by full name, first name, nickname or misspelling.
        - organization: a company, customer, vendor, agency, or an internal team or department.
        - project: a named initiative, program, product line or effort (a pilot, a migration, a launch).
        - service: a software system, application, API or component the company runs or builds.
        - technology: a third-party tool, platform, language, framework, cloud service or AI model.
        - concept: a theme, practice, process, problem or idea.
        - place: a location — a city, country, office or region.
        - other: none of these.

        And "canonical": when the topic is another name for one specific \
        thing — a first name or nickname of a listed person, an \
        abbreviation or acronym, a spelling variant, a shortened product \
        name — that thing's full name as usually written ("Carlos" → \
        "Carlos Ayala Gonzalez" when he is the only Carlos listed; "dynamo" \
        → "DynamoDB"). Otherwise null. Never map a topic to something \
        broader, narrower or merely related: "Claude Code" is not "Claude", \
        "Lead service" is not "Lead". A first name two listed people share \
        gets null.

        Return JSON of exactly this shape, with every topic exactly once:
        {"topics":[{"id":"T1","kind":"person","canonical":"Walter Martens"},{"id":"T2","kind":"technology","canonical":null}]}

        Use only the T identifiers given above.
        """

    static func refinementClassifyPrompt(meetings: String) -> String {
        let template = PromptStore.shared.get(.refinementClassify, default: defaultRefinementClassifyPrompt)
        return PromptStore.render(template, values: ["meetings": meetings])
    }

    static let refinementClassifySystemPrompt = """
        You sort past meetings by whether they refined a software feature. \
        You MUST respond with ONLY valid JSON matching the schema in the user \
        message — no prose, no markdown, no explanation before or after.
        """

    /// What counts as one feature, shared by the final analysis and the
    /// backfill so the two split meetings the same way. The failure it
    /// guards against: a design discussed at length (an outbox pattern, a
    /// queue) listed as a feature beside the feature it was designed for.
    static let refinementFeatureRules = """
        A feature is something that would get its own ticket: a capability of \
        the product or system, with its own intent and acceptance criteria. \
        The approach discussed for building a feature — its architecture, \
        design pattern, technology choice, data model, sequence of calls, or \
        retry and failure handling — is part of that feature, not a second \
        one. Name the feature, not the solution ("Async certificate \
        retention", not "Outbox pattern"). List a second feature only when it \
        has its own intent and its own acceptance criteria; when unsure, list \
        one. A feature that was only mentioned or given a status update does \
        not count.
        """

    /// The backfill's counterpart to the "refinement" field of the final
    /// analysis, for meetings analysed before that field existed. Works from
    /// the stored summary, not the transcript, which is what keeps checking
    /// a whole library cheap. Keep its criteria in step with the analysis
    /// prompt's.
    private static let defaultRefinementClassifyPrompt: String = """
        Below are summaries of past meetings, each with an identifier, title, \
        date and topics.

        MEETINGS
        {{meetings}}

        For every meeting, judge how likely (0.0-1.0) it is that a \
        substantial part of it was spent refining a software feature: \
        working out its intended behaviour, acceptance criteria, scope, edge \
        cases or design before or during implementation (backlog refinement, \
        grooming, a spec or design walkthrough, a feature kickoff). High \
        (0.7+) only when the group actually worked through what a feature \
        should do. Low for status updates, standups, incident reviews, 1:1s, \
        sales or support calls, and meetings that only mention a feature in \
        passing.

        Name each distinct feature the group refined, 2-6 words each, the \
        one that got the most attention first, at most 4 — and [] when the \
        likelihood is below 0.5. \(refinementFeatureRules)

        Return JSON of exactly this shape, with every meeting exactly once:
        {"meetings":[{"id":"M1","likelihood":0.8,"features":["Bulk invoice export","Client onboarding checklist"]},{"id":"M2","likelihood":0.1,"features":[]}]}

        Use only the M identifiers given above.
        """
}

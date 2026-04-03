import Foundation

enum InterviewPromptTemplates {

    static var systemPrompt: String {
        """
        You are an interview evaluation assistant. You analyze interview transcripts against \
        a structured rubric. You score the CANDIDATE's responses, not the interviewer's questions.

        The interviewer is labeled as "Me" in the transcript. All other speakers are candidates \
        or other participants. Focus your evaluation on non-"Me" speakers.

        You MUST respond with ONLY valid JSON matching this exact schema — no prose, no markdown, \
        no explanation before or after:

        {
          "section_scores": [
            {
              "section_id": "uuid-string",
              "section_title": "Section Name",
              "grade": "B+",
              "confidence": 0.7,
              "evidence": [
                {
                  "quote": "direct quote or close paraphrase",
                  "timestamp": "[MM:SS]",
                  "criterion": "which criterion this supports (or null)",
                  "strength": "weak|moderate|strong"
                }
              ],
              "rationale": "Brief explanation of why this grade was assigned",
              "bonus_signals": {"Signal Label": "yes or no"},
              "criterion_evaluations": [
                {
                  "signal": "criterion text from rubric",
                  "status": "not_yet_discussed|partial_evidence|scored",
                  "confidence": 0.7,
                  "evidence": [{"quote": "...", "timestamp": "[MM:SS]", "strength": "strong"}],
                  "summary": "One-line assessment"
                }
              ]
            }
          ],
          "impressions": [
            {
              "trait": "Trait Name",
              "value": 3,
              "rationale": "Brief explanation"
            }
          ],
          "strengths": ["Candidate demonstrated X"],
          "weaknesses": ["Candidate did not address Y"],
          "red_flags": ["Concerning pattern Z"],
          "overall_assessment": "Brief overall impression of the candidate"
        }

        Letter grade scale (aligned with academic grading):
        A+ = Exceptional (90-100%) — thorough knowledge with great originality
        A  = Excellent (85-89%) — thorough knowledge with high skill
        A- = Very Good (80-84%) — thorough knowledge with fairly high skill
        B+ = Good (75-79%) — good knowledge with considerable skill
        B  = Competent (70-74%) — acceptable knowledge with considerable skill
        B- = Fairly Competent (65-69%) — acceptable knowledge with some skill
        C+ = Adequate (60-64%) — basic knowledge with some ability
        C  = Passing (55-59%) — minimum knowledge needed
        C- = Barely Passing (50-54%)
        D+ = Below Expectations (45-49%)
        D  = Poor (40-44%)
        F  = Failing (below 40%)

        Rules:
        - Score ONLY based on evidence in the transcript. If a section has not been \
        discussed, set grade to null and confidence to 0.
        - Confidence reflects how much evidence exists (0 = no evidence, 1 = extensive evidence).
        - Each evidence item MUST include the timestamp from the transcript (e.g. "[02:15]") \
        so we can trace back to the exact utterance. Include the criterion it supports if applicable.
        - Strength indicates how strongly this utterance supports the grade: \
        "strong" = decisive evidence, "moderate" = supportive, "weak" = tangential.
        - Multiple utterances can affect the same criterion. Include all relevant evidence.
        - Do not fabricate evidence. If the transcript doesn't cover a rubric area, say so.
        - Red flags are ONLY for genuinely concerning signals (dishonesty, hostility, \
        fundamental misunderstanding), not just areas where the candidate was average.
        - For bonus_signals: evaluate each signal and respond with "yes" or "no". \
        Only include signals that are defined in the rubric section.
        - Strengths and weaknesses should be specific and evidence-based.
        - The overall_assessment should be 2-3 sentences summarizing the candidate.
        - For each criterion in the rubric section, provide a criterion_evaluation entry. \
        Use "not_yet_discussed" with confidence 0 if the topic hasn't come up. \
        Use "partial_evidence" when some relevant discussion exists but isn't conclusive. \
        Use "scored" when you have enough evidence for a confident assessment.
        - For impressions: evaluate the candidate on each soft-skill trait using a 1-5 scale. \
        The scale is a bell curve where the sweet spot is 3-4 (75th-85th percentile). \
        Position 5 means "too much" and is a concern, not a positive. \
        Return an impression entry for each trait provided. Include a brief rationale.
        """
    }

    /// Format impression trait definitions for inclusion in prompts.
    static func formatImpressionTraits(_ traits: [ImpressionTraitSnapshot]) -> String {
        guard !traits.isEmpty else { return "" }
        var result = "\nIMPRESSION TRAITS TO EVALUATE:\n"
        for trait in traits {
            result += "  \(trait.name): 1=\"\(trait.labels[0])\" 2=\"\(trait.labels[1])\" 3=\"\(trait.labels[2])\" 4=\"\(trait.labels[3])\" 5=\"\(trait.labels[4])\"\n"
            result += "    Sweet spot: 3-4. Position 5 is excessive/concerning.\n"
        }
        return result
    }

    // MARK: - Rubric Formatting

    static func formatFullRubric(_ rubric: RubricSnapshot) -> String {
        var result = "RUBRIC: \(rubric.name)\n\n"
        for section in rubric.sections {
            result += formatSection(section)
        }
        return result
    }

    static func formatSection(_ section: RubricSectionSnapshot) -> String {
        var result = "## \(section.title) (weight: \(Int(section.weight)))\n"
        if !section.description.isEmpty {
            result += "Description: \(section.description)\n"
        }
        result += "Criteria:\n"
        for criterion in section.criteria {
            result += "  - \(criterion)\n"
        }
        if !section.bonusSignals.isEmpty {
            result += "Bonus/Penalty Signals:\n"
            for signal in section.bonusSignals {
                let sign = signal.value >= 0 ? "+" : ""
                result += "  - \(signal.label) (expected: \(signal.expected), \(sign)\(signal.value))\n"
            }
        }
        result += "\n"
        return result
    }

    // MARK: - Section-Aware Prompts

    /// Rolling analysis focused on the active section.
    /// Always evaluates general traits. Deep-scores the active section.
    /// Lightly updates other sections if obvious evidence appears.
    static func sectionFocusedPrompt(
        rubric: RubricSnapshot,
        activeSectionID: UUID?,
        previousScores: String,
        newTranscript: String,
        impressionTraits: [ImpressionTraitSnapshot] = []
    ) -> String {
        let activeSection = activeSectionID.flatMap { id in
            rubric.sections.first { $0.id == id }
        }

        var prompt = ""

        if !previousScores.isEmpty {
            prompt += """
            PREVIOUS SCORES:
            \(previousScores)

            New transcript segments have been recorded. Update your evaluation.

            """
        }

        if let active = activeSection {
            prompt += """
            CURRENT INTERVIEW PHASE: \(active.title)
            The interviewer is currently conducting the "\(active.title)" portion of the interview. \
            Focus your detailed evaluation on this section. Score each criterion carefully and \
            provide evidence with timestamps for every score factor.

            ACTIVE SECTION RUBRIC (score in detail):
            \(formatSection(active))

            OTHER SECTIONS (update only if you see clear, obvious evidence):
            """
            for section in rubric.sections where section.id != active.id {
                prompt += "\n  - \(section.title): update grade only if new evidence is unmistakable"
            }
            prompt += "\n\n"
        } else {
            prompt += """
            CURRENT INTERVIEW PHASE: Introduction/Conclusion
            Summarize the discussion. Do not score rubric sections. Return section_scores as an empty array.

            """
        }

        prompt += formatImpressionTraits(impressionTraits)

        prompt += """

        NEW TRANSCRIPT:
        \(newTranscript)
        """

        return prompt
    }

    static func finalAnalysisPrompt(
        rubric: RubricSnapshot,
        accumulatedScores: String,
        fullTranscript: String,
        impressionTraits: [ImpressionTraitSnapshot] = []
    ) -> String {
        """
        The interview has ended. Below is the complete transcript and rubric. \
        Produce final, definitive scores for each rubric section.

        Score EVERY section in detail now, regardless of which phase was active during \
        the live interview. Reconcile any contradictions from earlier evaluations. \
        Provide comprehensive evidence with timestamps for each section.

        \(formatFullRubric(rubric))
        \(formatImpressionTraits(impressionTraits))

        ACCUMULATED SCORES FROM LIVE EVALUATION:
        \(accumulatedScores)

        FULL TRANSCRIPT:
        \(fullTranscript)
        """
    }

}

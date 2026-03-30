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
              "evidence": ["direct quote or close paraphrase from transcript"],
              "rationale": "Brief explanation of why this grade was assigned",
              "bonus_signals": {"Signal Label": "yes or no"}
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
        - Evidence array should contain 1-3 SHORT direct quotes or close paraphrases.
        - Do not fabricate evidence. If the transcript doesn't cover a rubric area, say so.
        - Red flags are ONLY for genuinely concerning signals (dishonesty, hostility, \
        fundamental misunderstanding), not just areas where the candidate was average.
        - For bonus_signals: evaluate each signal and respond with "yes" or "no". \
        Only include signals that are defined in the rubric section.
        - Strengths and weaknesses should be specific and evidence-based.
        - The overall_assessment should be 2-3 sentences summarizing the candidate.
        """
    }

    static func formatRubric(_ rubric: RubricSnapshot) -> String {
        var result = "RUBRIC: \(rubric.name)\n\n"
        for section in rubric.sections {
            result += "## \(section.title) (weight: \(Int(section.weight)))\n"
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
        }
        return result
    }

    static func initialAnalysisPrompt(rubric: RubricSnapshot, transcript: String) -> String {
        """
        Evaluate the following interview transcript against the rubric.

        \(formatRubric(rubric))

        TRANSCRIPT:
        \(transcript)
        """
    }

    static func rollingAnalysisPrompt(
        rubric: RubricSnapshot,
        previousScores: String,
        newTranscript: String
    ) -> String {
        """
        Here are the previous scores from this interview:

        PREVIOUS SCORES:
        \(previousScores)

        New transcript segments have been recorded. Update your evaluation with the new evidence. \
        Adjust grades up or down as warranted. Do not drop sections.

        \(formatRubric(rubric))

        NEW TRANSCRIPT:
        \(newTranscript)
        """
    }

    static func finalAnalysisPrompt(
        rubric: RubricSnapshot,
        accumulatedScores: String,
        fullTranscript: String
    ) -> String {
        """
        The interview has ended. Below is the complete transcript and rubric. \
        Produce final, definitive scores for each rubric section.

        Reconcile any contradictions from earlier rolling evaluations. \
        Highlight the strongest evidence for each section. \
        Provide a comprehensive overall_assessment.

        \(formatRubric(rubric))

        ACCUMULATED SCORES FROM LIVE EVALUATION:
        \(accumulatedScores)

        FULL TRANSCRIPT:
        \(fullTranscript)
        """
    }
}

import SwiftUI
import SwiftData
import AppKit

/// Load a saved transcript and test it against a rubric without recording.
struct TranscriptTestView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Rubric.createdAt, order: .reverse) private var rubrics: [Rubric]

    @State private var loadedTranscript: TranscriptFile?
    @State private var selectedRubric: Rubric?
    @State private var isAnalyzing = false
    @State private var analysisError: String?
    @State private var result: InterviewAnalysisResult?
    @State private var criterionEvals: [UUID: [CriterionEvaluationSnapshot]] = [:]

    private var activeRubrics: [Rubric] {
        rubrics.filter { !$0.isArchived }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Button {
                    loadTranscript()
                } label: {
                    Label(loadedTranscript == nil ? "Load Transcript" : "Change Transcript", systemImage: "doc.badge.arrow.up")
                }
                .controlSize(.small)

                if let transcript = loadedTranscript {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(transcript.title)
                            .font(.caption.weight(.semibold))
                        Text("\(transcript.segments.count) segments · \(formatDuration(transcript.duration))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Picker("Rubric", selection: $selectedRubric) {
                    Text("Select rubric...").tag(nil as Rubric?)
                    ForEach(activeRubrics) { rubric in
                        Text(rubric.name).tag(rubric as Rubric?)
                    }
                }
                .frame(maxWidth: 250)
                .controlSize(.small)

                Button {
                    Task { await runAnalysis() }
                } label: {
                    if isAnalyzing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Analyze", systemImage: "brain")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(loadedTranscript == nil || selectedRubric == nil || isAnalyzing)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if let error = analysisError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { analysisError = nil }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            if let result {
                // Results
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(result.sectionScores, id: \.sectionID) { score in
                            testResultSection(score)
                        }

                        if !result.strengths.isEmpty {
                            signalList("Strengths", items: result.strengths, color: .green)
                        }
                        if !result.weaknesses.isEmpty {
                            signalList("Weaknesses", items: result.weaknesses, color: .orange)
                        }
                        if !result.redFlags.isEmpty {
                            signalList("Red Flags", items: result.redFlags, color: .red)
                        }

                        if !result.overallAssessment.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Overall Assessment")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(result.overallAssessment)
                                    .font(.caption)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            } else if loadedTranscript == nil {
                ContentUnavailableView(
                    "Load a Transcript",
                    systemImage: "doc.badge.arrow.up",
                    description: Text("Load a saved transcript file to test against rubrics")
                )
            } else {
                ContentUnavailableView(
                    "Ready to Analyze",
                    systemImage: "brain",
                    description: Text("Select a rubric and click Analyze to test")
                )
            }
        }
    }

    // MARK: - Result Section

    private func testResultSection(_ score: SectionScoreSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(score.sectionTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let gradeStr = score.grade, let grade = LetterGrade(rawValue: gradeStr) {
                    Text(grade.label)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(grade.color)
                }
            }

            // Per-criterion evaluations
            let evals = score.criterionEvaluations
            if !evals.isEmpty {
                ForEach(evals, id: \.signal) { eval in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: statusIcon(eval.status))
                            .font(.system(size: 10))
                            .foregroundStyle(statusColor(eval.status))
                            .frame(width: 14)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(eval.signal)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(eval.status == .notYetDiscussed ? .tertiary : .primary)
                                Spacer()
                                if eval.confidence > 0 {
                                    Text("\(Int(eval.confidence * 100))%")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let summary = eval.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(eval.evidence, id: \.quote) { ev in
                                HStack(spacing: 4) {
                                    if !ev.timestamp.isEmpty {
                                        Text(ev.timestamp)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text("\"\(ev.quote)\"")
                                        .font(.caption)
                                        .italic()
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.leading, 4)
                            }
                        }
                    }
                }
            }

            if !score.rationale.isEmpty {
                Text(score.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }

    // MARK: - Helpers

    private func signalList(_ title: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                Text("  \(item)")
                    .font(.caption)
            }
        }
        .padding(.horizontal)
    }

    private func statusIcon(_ status: CriterionStatus) -> String {
        switch status {
        case .scored: "checkmark.circle.fill"
        case .partialEvidence: "circle.dotted"
        case .notYetDiscussed: "circle"
        }
    }

    private func statusColor(_ status: CriterionStatus) -> Color {
        switch status {
        case .scored: .green
        case .partialEvidence: .yellow
        case .notYetDiscussed: .gray
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let min = Int(duration) / 60
        let sec = Int(duration) % 60
        return String(format: "%d:%02d", min, sec)
    }

    // MARK: - Load & Analyze

    private func loadTranscript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.title = "Load Transcript"
        panel.message = "Select a saved transcript file (.getranscript.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            loadedTranscript = try TranscriptFile.read(from: url)
            result = nil
            criterionEvals = [:]
        } catch {
            analysisError = "Failed to load: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func runAnalysis() async {
        guard let transcript = loadedTranscript, let rubric = selectedRubric else { return }
        isAnalyzing = true
        analysisError = nil
        result = nil

        defer { isAnalyzing = false }

        guard let client = try? await AIClientFactory.makeClient() else {
            analysisError = "AI not configured. Check Settings."
            return
        }

        let rubricSnapshot = rubric.toSnapshot()
        let service = InterviewIntelligenceService(
            client: client,
            rubricContext: rubricSnapshot
        )

        do {
            // Run full analysis on the complete transcript
            if let analysisResult = try await service.performFinalInterviewAnalysis(segments: transcript.segments) {
                self.result = analysisResult
                for score in analysisResult.sectionScores {
                    criterionEvals[score.sectionID] = score.criterionEvaluations
                }
            } else {
                analysisError = "Analysis returned no results."
            }
        } catch {
            analysisError = error.localizedDescription
        }
    }
}

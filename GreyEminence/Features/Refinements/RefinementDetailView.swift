import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One refinement meeting: build its report, read it laid out by section,
/// then export it or file a Jira ticket from it.
struct RefinementDetailView: View {
    let topic: RefinementTopic
    @Bindable var meeting: Meeting
    /// Opens the meeting, scrolled to a transcript line when one is given.
    var onOpenMeeting: (Meeting, UUID?) -> Void
    var onOpenJiraSettings: () -> Void

    private var store = RefinementReportStore.shared
    @State private var showTicketSheet = false
    @State private var exportMessage: String?

    init(topic: RefinementTopic, onOpenMeeting: @escaping (Meeting, UUID?) -> Void, onOpenJiraSettings: @escaping () -> Void) {
        self.topic = topic
        _meeting = Bindable(topic.meeting)
        self.onOpenMeeting = onOpenMeeting
        self.onOpenJiraSettings = onOpenJiraSettings
    }

    enum Tab: String, CaseIterable, Identifiable {
        case rationale = "Rationale"
        case spec = "Effective Spec"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .rationale
    @State private var selectedCitation: Int?
    /// The transcript as panel lines, rebuilt when the transcript changes.
    @State private var lines: [RefinementPassage.Line] = []
    /// Shared with the rest of the app's inspector panes (⇧⌘I).
    @AppStorage("showInspector") private var showInspector = true

    /// Past this, lines get too long to read; the extra width stays margin.
    static let maxContentWidth: CGFloat = 980
    static let evidencePanelWidth: CGFloat = 360

    private var report: RefinementReport? { store.report(for: topic) }
    private var isGenerating: Bool { store.isGenerating(topic) }

    /// Fingerprint of the transcript as it is now, compared against the
    /// report's to flag one written before a re-transcription or speaker
    /// fix. Cached: it walks and hashes the whole transcript.
    @State private var currentFingerprint: String?

    private var isStale: Bool {
        guard let report, let currentFingerprint else { return false }
        return report.transcriptFingerprint != currentFingerprint
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report, !isGenerating {
                switch tab {
                case .rationale:
                    HStack(spacing: 0) {
                        scrolling {
                            RefinementRationaleView(
                                content: report.content,
                                citations: RefinementReportLayout.Citations(
                                    index: RefinementEvidenceIndex(report.content),
                                    selected: selectedCitation,
                                    onSelect: { number in
                                        selectedCitation = number
                                        showInspector = true
                                    }
                                )
                            )
                        }
                        if showInspector {
                            Divider()
                            RefinementEvidencePanel(
                                index: RefinementEvidenceIndex(report.content),
                                lines: lines,
                                selected: $selectedCitation,
                                onOpenLine: { onOpenMeeting(meeting, $0) }
                            )
                            .frame(width: Self.evidencePanelWidth)
                        }
                    }
                case .spec:
                    scrolling {
                        RefinementSpecCard(spec: report.content.spec, showsCopy: true)
                            .frame(maxWidth: 820, alignment: .leading)
                    }
                }
            } else {
                scrolling {
                    if isGenerating {
                        generatingState
                    } else if store.error(for: topic) == nil {
                        emptyState
                    }
                }
            }
        }
        .task(id: "\(meeting.id)-\(meeting.segments.count)-\(meeting.transcriptionModel ?? "")") {
            currentFingerprint = RefinementReportService.fingerprint(of: RefinementReportService.transcript(for: meeting))
            lines = meeting.segments
                .sorted { $0.startTime < $1.startTime }
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { RefinementPassage.Line(id: $0.id, startTime: $0.startTime, speaker: $0.speaker.displayName, text: $0.text) }
        }
        .sheet(isPresented: $showTicketSheet) {
            if let report {
                JiraTicketSheet(topic: topic, report: report, onOpenJiraSettings: onOpenJiraSettings)
            }
        }
    }

    /// Banners above whatever the pane shows, in one scroll view.
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                banners
                content()
            }
            .padding(20)
            .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.feature)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                if topic.count > 1 {
                    Text("One of \(topic.count) features refined in this meeting: \(meeting.refinementTopics.joined(separator: " · "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Button(meeting.title) { onOpenMeeting(meeting, nil) }
                        .buttonStyle(.link)
                        .help("Open the meeting")
                    Text("·")
                    Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(meeting.formattedDuration)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let report, !isGenerating {
                    Text("Report generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(RefinementReportService.modelLabel(report.modelIdentifier))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.top, 6)
                }
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                onOpenMeeting(meeting, nil)
            } label: {
                Label("Open Meeting", systemImage: "arrow.up.forward.app")
            }
            .help("Go to this meeting's summary and transcript")

            if isGenerating {
                Button("Cancel") { store.cancel(topic) }
            } else if report != nil {
                Button {
                    store.generate(for: topic)
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .help("Run the analysis again on the current transcript. Replaces this report.")
            }

            if let report, !isGenerating {
                Menu {
                    Button("Copy Full Report as Markdown") {
                        copy(RefinementReportMarkdown.full(report.content, title: topic.feature, date: meeting.date))
                    }
                    Button("Copy Spec as Markdown") {
                        copy(RefinementReportMarkdown.spec(report.content.spec))
                    }
                    Divider()
                    Button("Export PDF — Full Report…") { exportPDF(report, scope: .full) }
                    Button("Export PDF — Spec Only…") { exportPDF(report, scope: .specOnly) }
                    Divider()
                    Button("Save as Markdown…") { save(report) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .fixedSize()

                if let issue = report.jiraIssue {
                    Button {
                        NSWorkspace.shared.open(issue.url)
                    } label: {
                        Label(issue.key, systemImage: "ticket.fill")
                    }
                    .help("Open \(issue.key) in Jira")
                } else {
                    Button {
                        showTicketSheet = true
                    } label: {
                        Label("Create Jira Ticket…", systemImage: "ticket")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .controlSize(.regular)
    }

    // MARK: - States

    @ViewBuilder
    private var banners: some View {
        if let error = store.error(for: topic) {
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: "Couldn't build the report: \(error)") {
                Button("Try Again") { store.generate(for: topic) }
                Button("Dismiss") { store.dismissError(for: topic) }
            }
        }
        if let exportMessage {
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: exportMessage) {
                Button("Dismiss") { self.exportMessage = nil }
            }
        }
        if !isGenerating, isStale {
            Banner(systemImage: "clock.arrow.circlepath", tint: .orange, text: "The transcript has changed since this report was written.") {
                Button("Regenerate") { store.generate(for: topic) }
            }
        }
        if let report, !isGenerating, !report.content.isRefinement {
            Banner(systemImage: "questionmark.circle", tint: .secondary, text: "This meeting doesn't look like a feature refinement.") {
                Button("Remove from Refinements") { meeting.refinementOverride = false }
            }
        }
    }

    /// No report yet: a compact call to action, then what the meeting was
    /// about — enough to confirm it's the one you meant before paying for a
    /// report.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button {
                    store.generate(for: topic)
                } label: {
                    Label("Build Refinement Report", systemImage: RefinementStyle.symbol)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(meeting.segments.isEmpty)
                Text(meeting.segments.isEmpty
                     ? "This meeting has no transcript."
                     : "Works out what the meeting decided about \(topic.feature), with citations to the transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            meetingSummary
        }
    }

    private var generatingState: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reconstructing what the meeting decided…")
                    Text("A long meeting can take a couple of minutes. You can look at other meetings meanwhile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            meetingSummary
        }
    }

    /// The meeting's own summary, as the meeting inspector shows it.
    @ViewBuilder
    private var meetingSummary: some View {
        if let summary = meeting.latestInsight?.summary, !summary.isEmpty {
            AISummarySection(summary: summary)
        } else {
            Text("This meeting has no summary yet.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Export

    private func copy(_ markdown: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Plain Markdown on purpose: tickets and PR descriptions render it.
        pasteboard.setString(markdown, forType: .string)
    }

    private func save(_ report: RefinementReport) {
        let title = topic.feature
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.suggestedFilename(title: title, date: meeting.date)
        panel.title = "Save Refinement Report"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RefinementReportMarkdown.full(report.content, title: title, date: meeting.date)
                .write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func exportPDF(_ report: RefinementReport, scope: RefinementPDFExporter.Scope) {
        let feature = topic.feature
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Self.suggestedFilename(title: feature, date: meeting.date, suffix: scope == .full ? "refinement" : "spec", fileExtension: "pdf")
        panel.title = scope == .full ? "Export Refinement Report" : "Export Refinement Spec"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RefinementPDFExporter.write(report, scope: scope, feature: feature, meeting: meeting, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportMessage = "Couldn't export the PDF: \(error.localizedDescription)"
        }
    }

    /// "Bulk Invoice Export — 2026-09-23 (refinement).md"
    nonisolated static func suggestedFilename(title: String, date: Date, suffix: String = "refinement", fileExtension: String = "md") -> String {
        let calendar = Calendar.current
        let day = String(
            format: "%04d-%02d-%02d",
            calendar.component(.year, from: date),
            calendar.component(.month, from: date),
            calendar.component(.day, from: date)
        )
        return "\(title) — \(day) (\(suffix))".sanitizedForFilename() + ".\(fileExtension)"
    }
}

private struct Banner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            actions
                .controlSize(.small)
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

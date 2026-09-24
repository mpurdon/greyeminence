import AppKit
import SwiftUI

/// Draft a Jira ticket from a refinement report, edit it, create it.
///
/// The description is Markdown in an editor — converted to Atlassian
/// Document Format only on submit — so what you see is what you can change.
struct JiraTicketSheet: View {
    let topic: RefinementTopic
    private var meeting: Meeting { topic.meeting }
    let report: RefinementReport
    var onOpenJiraSettings: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var projectKey = JiraSettings.defaultProject
    @State private var issueType = JiraSettings.defaultIssueTypeName
    @State private var summary = ""
    @State private var labels = ""
    @State private var scope: Scope = .spec
    @State private var descriptionText = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let isConfigured = JiraSettings.isConfigured

    enum Scope: String, CaseIterable, Identifiable {
        case spec = "Spec only"
        case full = "Full report"
        var id: String { rawValue }
    }

    init(topic: RefinementTopic, report: RefinementReport, onOpenJiraSettings: @escaping () -> Void) {
        self.topic = topic
        self.report = report
        self.onOpenJiraSettings = onOpenJiraSettings
    }

    private var canCreate: Bool {
        isConfigured && !isCreating
            && projectKey.nonEmpty != nil && issueType.nonEmpty != nil
            && summary.nonEmpty != nil && descriptionText.nonEmpty != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Jira Ticket")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            Divider()
            if isConfigured {
                form
            } else {
                notConfigured
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 600)
        .onAppear {
            summary = topic.feature
            descriptionText = Self.draftDescription(for: scope, report: report, feature: topic.feature, meeting: meeting)
        }
        .onChange(of: scope) { _, newScope in
            descriptionText = Self.draftDescription(for: newScope, report: report, feature: topic.feature, meeting: meeting)
        }
    }

    private var form: some View {
        Form {
            HStack(spacing: 12) {
                TextField("Project", text: $projectKey, prompt: Text("PROJ"))
                    .frame(width: 150)
                TextField("Type", text: $issueType, prompt: Text(JiraSettings.defaultIssueType))
                    .frame(width: 180)
            }
            TextField("Summary", text: $summary)
            TextField("Labels", text: $labels, prompt: Text("comma-separated, optional"))
            Picker("Description", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextEditor(text: $descriptionText)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 260)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
            Text("Markdown headings, bullets, **bold** and _italic_ become Jira formatting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var notConfigured: some View {
        ContentUnavailableView {
            Label("Jira Isn't Set Up", systemImage: "ticket")
        } description: {
            Text("Add your Jira site, email and an API token to create tickets from the app.")
        } actions: {
            Button("Open Jira Settings") {
                dismiss()
                onOpenJiraSettings()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if isCreating { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create Ticket", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .padding()
    }

    private func create() {
        guard let credentials = JiraSettings.credentials() else {
            errorMessage = JiraClient.JiraError.notConfigured.localizedDescription
            return
        }
        isCreating = true
        errorMessage = nil
        let project = projectKey.trimmingCharacters(in: .whitespaces).uppercased()
        let type = issueType.trimmingCharacters(in: .whitespaces)
        let title = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = descriptionText
        let labelList = Self.labels(from: labels)
        let meetingID = meeting.id
        let topic = topic

        Task {
            defer { isCreating = false }
            do {
                let issue = try await JiraClient(credentials: credentials).createIssue(
                    projectKey: project,
                    issueType: type,
                    summary: title,
                    descriptionMarkdown: body,
                    labels: labelList
                )
                RefinementReportStore.shared.attach(issue, to: topic)
                LogManager.send("Created Jira issue \(issue.key) from refinement report", category: .general, meetingID: meetingID)
                NSWorkspace.shared.open(issue.url)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Jira labels can't contain spaces; turn "needs review" into
    /// "needs-review" rather than letting the whole request fail.
    nonisolated static func labels(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-") }
            .filter { !$0.isEmpty }
    }

    static func draftDescription(for scope: Scope, report: RefinementReport, feature: String, meeting: Meeting) -> String {
        let title = feature
        let body: String
        switch scope {
        case .spec:
            body = RefinementReportMarkdown.spec(report.content.spec)
        case .full:
            // Drop the document title and date line: the ticket's summary
            // already names the feature.
            body = RefinementReportMarkdown.full(report.content, title: title, date: meeting.date)
                .components(separatedBy: "\n\n")
                .dropFirst(2)
                .joined(separator: "\n\n")
        }
        return body + "\n\n---\n\n_From the refinement meeting \"\(meeting.title)\" on \(meeting.date.formatted(date: .long, time: .omitted))._\n"
    }
}

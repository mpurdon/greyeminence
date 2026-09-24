import SwiftUI

/// Jira Cloud connection for creating tickets from refinement reports.
struct JiraSettingsView: View {
    @AppStorage(JiraSettings.siteKey) private var site = ""
    @AppStorage(JiraSettings.emailKey) private var email = ""
    @AppStorage(JiraSettings.projectKey) private var projectKey = ""
    @AppStorage(JiraSettings.issueTypeKey) private var issueType = JiraSettings.defaultIssueType

    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case testing
        case connected(String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Site") {
                    TextField("your-company.atlassian.net", text: $site)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
                if !site.isEmpty, let resolved = JiraSettings.normalizedSite(site) {
                    Text("Uses \(resolved.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Email") {
                    TextField("you@company.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
                LabeledContent("API token") {
                    HStack {
                        SecureField(hasStoredToken ? "Saved in Keychain" : "Paste token", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onSubmit(saveToken)
                        Button("Save", action: saveToken)
                            .disabled(token.isEmpty)
                        if hasStoredToken {
                            Button("Remove", role: .destructive, action: removeToken)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Link("Create an API token at id.atlassian.com",
                     destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                    .font(.caption)

                HStack {
                    Button("Test Connection", action: testConnection)
                        .disabled(testState == .testing)
                    switch testState {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView().controlSize(.small)
                    case .connected(let name):
                        Label("Connected as \(name)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .lineLimit(3)
                    }
                }
            } header: {
                Label("Jira Cloud", systemImage: "ticket")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            } footer: {
                Text("Used to create tickets from refinement reports. The token is stored in your Keychain and sent only to your Jira site.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Project key") {
                    TextField("PROJ", text: $projectKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                LabeledContent("Issue type") {
                    TextField(JiraSettings.defaultIssueType, text: $issueType)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            } header: {
                Label("New Tickets", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            } footer: {
                Text("Defaults for the ticket draft; you can change both before creating each one. The issue type must match a type in the project exactly, e.g. Story, Task or Feature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasStoredToken = ((try? KeychainHelper.get(JiraSettings.tokenKeychainKey)) ?? nil)?.isEmpty == false
        }
        .onChange(of: site) { testState = .idle }
        .onChange(of: email) { testState = .idle }
    }

    private func saveToken() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainHelper.set(trimmed, key: JiraSettings.tokenKeychainKey)
            token = ""
            hasStoredToken = true
            testState = .idle
        } catch {
            testState = .failed("Couldn't save the token: \(error.localizedDescription)")
        }
    }

    private func removeToken() {
        try? KeychainHelper.remove(JiraSettings.tokenKeychainKey)
        hasStoredToken = false
        testState = .idle
    }

    private func testConnection() {
        if !token.isEmpty { saveToken() }
        guard let credentials = JiraSettings.credentials() else {
            testState = .failed("Enter the site, email and API token first.")
            return
        }
        testState = .testing
        Task {
            do {
                let name = try await JiraClient(credentials: credentials).myself()
                testState = .connected(name)
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

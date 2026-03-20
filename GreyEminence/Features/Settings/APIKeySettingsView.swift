import SwiftUI
import UniformTypeIdentifiers

struct APIKeySettingsView: View {
    @AppStorage("aiProvider") private var selectedProvider: String = "anthropic"
    @AppStorage("claudeModel") private var selectedModel: String = "claude-sonnet-4-20250514"
    @AppStorage("awsProfile") private var awsProfile: String = "default"
    @AppStorage("awsRegion") private var awsRegion: String = "us-east-1"

    @State private var apiKey: String = ""
    @State private var isKeyVisible = false
    @State private var isSaved = false
    @State private var isValidating = false
    @State private var validationResult: ValidationResult?
    @State private var availableProfiles: [String] = []
    @State private var hasAWSAccess = false
    @State private var hasClaudeConfig = false
    @State private var isSSOLoggingIn = false

    private enum ValidationResult {
        case success
        case failure(String)
    }

    private var isAnthropic: Bool { selectedProvider == "anthropic" }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $selectedProvider) {
                    Text("Anthropic API").tag("anthropic")
                    Text("AWS Bedrock").tag("bedrock")
                }
                .onChange(of: selectedProvider) {
                    validationResult = nil
                }
            } header: {
                Label("Provider", systemImage: "cloud")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            if isAnthropic {
                anthropicSection
            } else {
                bedrockSection
            }

            modelSection
        }
        .formStyle(.grouped)
        .onAppear {
            loadAPIKey()
            refreshAWSProfiles()
        }
    }

    // MARK: - Anthropic

    private var anthropicSection: some View {
        Section {
            HStack {
                if isKeyVisible {
                    TextField("sk-ant-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                } else {
                    SecureField("sk-ant-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    isKeyVisible.toggle()
                } label: {
                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Button("Save to Keychain") {
                    saveAPIKey()
                }
                .disabled(apiKey.isEmpty)

                if isSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                Spacer()

                validationStatus

                Button("Validate") {
                    validateAnthropic()
                }
                .disabled(apiKey.isEmpty || isValidating)
            }

            Text("Your API key is stored securely in the macOS Keychain and never transmitted except to the Claude API.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Claude API Key", systemImage: "key")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    // MARK: - Bedrock

    private var bedrockSection: some View {
        Section {
            HStack {
                if hasAWSAccess {
                    Label("~/.aws", systemImage: "folder.fill")
                        .font(.caption)
                        .fontDesign(.monospaced)
                } else {
                    Text("Grant access to your ~/.aws directory")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Locate ~/.aws...") {
                    locateAWSDirectory()
                }
            }

            if hasAWSAccess {
                if availableProfiles.isEmpty {
                    Text("No profiles found in credentials file")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Picker("AWS Profile", selection: $awsProfile) {
                        ForEach(availableProfiles, id: \.self) { profile in
                            Text(profile).tag(profile)
                        }
                    }
                    .onChange(of: awsProfile) {
                        if let detectedRegion = AWSCredentialLoader.loadRegion(profile: awsProfile) {
                            awsRegion = detectedRegion
                        }
                        validationResult = nil
                    }
                }
            }

            Picker("Region", selection: $awsRegion) {
                Text("US East (N. Virginia)").tag("us-east-1")
                Text("US East (Ohio)").tag("us-east-2")
                Text("US West (Oregon)").tag("us-west-2")
                Text("EU (Ireland)").tag("eu-west-1")
                Text("EU (Frankfurt)").tag("eu-central-1")
                Text("EU (Paris)").tag("eu-west-3")
                Text("Asia Pacific (Tokyo)").tag("ap-northeast-1")
                Text("Asia Pacific (Sydney)").tag("ap-southeast-2")
            }

            HStack {
                if isSSOLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for browser...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("SSO Login") {
                    performSSOLogin()
                }
                .disabled(availableProfiles.isEmpty || isSSOLoggingIn)

                Spacer()

                validationStatus

                Button("Validate") {
                    validateBedrock()
                }
                .disabled(availableProfiles.isEmpty || isValidating)
            }

            HStack {
                if hasClaudeConfig {
                    Label("trajector-settings.json", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Optional: inference profile config")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Locate Config...") {
                    locateClaudeConfig()
                }
            }

            if hasClaudeConfig, let settings = TrajectorSettings.load() {
                if let model = settings.sonnetModel {
                    LabeledContent("Sonnet") {
                        Text(model.split(separator: "/").last.map(String.init) ?? model)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("Uses your local AWS credentials via SSO. Optionally load inference profile ARNs from ~/.claude/trajector-settings.json.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("AWS Configuration", systemImage: "server.rack")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $selectedModel) {
                Text("Opus 4 (Most capable)").tag("claude-opus-4-20250514")
                Text("Sonnet 4 (Balanced)").tag("claude-sonnet-4-20250514")
                Text("Haiku 3.5 (Fastest)").tag("claude-haiku-4-5-20251001")
            }

            LabeledContent("Analysis Interval") {
                Text("~45 seconds")
            }

            Text("Meeting intelligence uses Claude to generate summaries, action items, and follow-up questions from your meeting transcript. Model changes apply to the next recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Usage", systemImage: "chart.bar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    // MARK: - Shared UI

    @ViewBuilder
    private var validationStatus: some View {
        if isValidating {
            ProgressView()
                .controlSize(.small)
        }

        if let validationResult {
            switch validationResult {
            case .success:
                Label("Valid", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Actions

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainHelper.set(trimmed, key: AIPromptTemplates.keychainKey)
            isSaved = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                isSaved = false
            }
        } catch {
            // Keychain save failed silently — key stays in memory only
        }
    }

    private func refreshAWSProfiles() {
        AWSCredentialLoader.restoreAccess()
        hasAWSAccess = AWSCredentialLoader.hasBookmark
        availableProfiles = AWSCredentialLoader.availableProfiles()
        hasClaudeConfig = TrajectorSettings.load() != nil

        // Auto-populate from trajector settings if available
        if let settings = TrajectorSettings.load() {
            if let profile = settings.awsProfile, availableProfiles.contains(profile) {
                awsProfile = profile
            }
            if let region = settings.awsRegion {
                awsRegion = region
            }
        }
    }

    private func locateAWSDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Select your ~/.aws directory"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        if panel.runModal() == .OK, let url = panel.url {
            AWSCredentialLoader.persistAccess(to: url)
            refreshAWSProfiles()
        }
    }

    private func locateClaudeConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = [.json]
        panel.message = "Select ~/.claude/trajector-settings.json"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")

        if panel.runModal() == .OK, let url = panel.url {
            TrajectorSettings.persistAccess(to: url)
            hasClaudeConfig = TrajectorSettings.load() != nil
            refreshAWSProfiles()
        }
    }

    private func loadAPIKey() {
        apiKey = (try? KeychainHelper.get(AIPromptTemplates.keychainKey)) ?? ""
    }

    private func validateAnthropic() {
        isValidating = true
        validationResult = nil
        Task {
            do {
                let client = ClaudeAPIClient(
                    apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: selectedModel
                )
                _ = try await client.sendMessage(
                    system: "Reply with exactly: OK",
                    userContent: "Reply OK",
                    maxTokens: 16
                )
                validationResult = .success
            } catch {
                validationResult = .failure(error.localizedDescription)
            }
            isValidating = false
            Task {
                try? await Task.sleep(for: .seconds(5))
                validationResult = nil
            }
        }
    }

    private func performSSOLogin() {
        guard let config = AWSCredentialLoader.parseSSOConfig(profile: awsProfile) else {
            validationResult = .failure("Profile '\(awsProfile)' has no SSO configuration")
            return
        }

        isSSOLoggingIn = true
        validationResult = nil
        Task {
            do {
                _ = try await AWSSSOLoginService.login(config: config)
                validationResult = .success
            } catch {
                validationResult = .failure(error.localizedDescription)
            }
            isSSOLoggingIn = false
            Task {
                try? await Task.sleep(for: .seconds(5))
                validationResult = nil
            }
        }
    }

    private func validateBedrock() {
        isValidating = true
        validationResult = nil
        Task {
            do {
                let credentials = try await AWSCredentialLoader.loadCredentials(profile: awsProfile)
                let bedrockModel = AIClientFactory.resolveBedrockModel(for: selectedModel)
                let client = BedrockAPIClient(
                    credentials: credentials,
                    region: awsRegion,
                    model: bedrockModel
                )
                _ = try await client.sendMessage(
                    system: "Reply with exactly: OK",
                    userContent: "Reply OK",
                    maxTokens: 16
                )
                validationResult = .success
            } catch {
                validationResult = .failure(error.localizedDescription)
            }
            isValidating = false
            Task {
                try? await Task.sleep(for: .seconds(5))
                validationResult = nil
            }
        }
    }
}

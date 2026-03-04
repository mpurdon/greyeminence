import SwiftUI

struct APIKeySettingsView: View {
    @State private var apiKey: String = ""
    @State private var isKeyVisible = false
    @State private var isSaved = false
    @State private var isValidating = false
    @State private var validationResult: ValidationResult?
    @AppStorage("claudeModel") private var selectedModel: String = "claude-sonnet-4-20250514"

    private enum ValidationResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
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

                    Button("Validate") {
                        validateAPIKey()
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
        .formStyle(.grouped)
        .onAppear {
            loadAPIKey()
        }
    }

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

    private func loadAPIKey() {
        apiKey = (try? KeychainHelper.get(AIPromptTemplates.keychainKey)) ?? ""
    }

    private func validateAPIKey() {
        isValidating = true
        validationResult = nil
        Task {
            do {
                let client = ClaudeAPIClient(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), model: selectedModel)
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

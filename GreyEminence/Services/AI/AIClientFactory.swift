import Foundation

enum AIProvider: String {
    case anthropic
    case bedrock
}

enum AIClientFactory {
    static func makeClient() async throws -> (any AIClient)? {
        let providerRaw = UserDefaults.standard.string(forKey: "aiProvider") ?? "anthropic"
        let provider = AIProvider(rawValue: providerRaw) ?? .anthropic
        let model = UserDefaults.standard.string(forKey: "claudeModel") ?? "claude-sonnet-4-20250514"

        switch provider {
        case .anthropic:
            guard let apiKey = try KeychainHelper.get(AIPromptTemplates.keychainKey),
                  !apiKey.isEmpty else {
                return nil
            }
            return ClaudeAPIClient(apiKey: apiKey, model: model)

        case .bedrock:
            let profile = UserDefaults.standard.string(forKey: "awsProfile") ?? "default"
            let region = UserDefaults.standard.string(forKey: "awsRegion") ?? "us-east-1"
            AWSCredentialLoader.restoreAccess()
            let credentials = try await AWSCredentialLoader.loadCredentials(profile: profile)
            let bedrockModel = resolveBedrockModel(for: model)
            return BedrockAPIClient(credentials: credentials, region: region, model: bedrockModel)
        }
    }

    /// Resolve model: prefer inference profile ARN from trajector settings, fall back to foundation model ID
    static func resolveBedrockModel(for anthropicModel: String) -> String {
        let settings = TrajectorSettings.load()

        // Map the UI model choice to the corresponding inference profile ARN
        switch anthropicModel {
        case "claude-opus-4-20250514":
            if let arn = settings?.opusModel { return arn }
        case "claude-sonnet-4-20250514":
            if let arn = settings?.sonnetModel { return arn }
        case "claude-haiku-4-5-20251001":
            if let arn = settings?.haikuModel { return arn }
        default:
            break
        }

        // Fall back to foundation model ID
        return foundationModelId(for: anthropicModel)
    }

    static func foundationModelId(for anthropicModel: String) -> String {
        switch anthropicModel {
        case "claude-opus-4-20250514":
            "anthropic.claude-opus-4-20250514-v1:0"
        case "claude-sonnet-4-20250514":
            "anthropic.claude-sonnet-4-20250514-v1:0"
        case "claude-haiku-4-5-20251001":
            "anthropic.claude-haiku-4-5-20251001-v1:0"
        default:
            "anthropic.\(anthropicModel)-v1:0"
        }
    }
}

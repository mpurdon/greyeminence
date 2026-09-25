import Foundation

enum AIProvider: String {
    case anthropic
    case bedrock
}

enum AIClientFactory {
    static func makeClient() async throws -> (any AIClient)? {
        let providerRaw = UserDefaults.standard.string(forKey: "aiProvider") ?? "anthropic"
        let provider = AIProvider(rawValue: providerRaw) ?? .anthropic
        return try await makeClient(provider: provider, model: AIModelCatalog.mainModel)
    }

    /// Client for per-frame vision analysis. Defaults to Haiku — frame
    /// descriptions don't need the main model's depth, and Haiku is ~2×
    /// cheaper per token than Sonnet 5. Session synthesis and transcript
    /// analysis stay on `makeClient()`.
    static func makeFrameAnalysisClient() async throws -> (any AIClient)? {
        let providerRaw = UserDefaults.standard.string(forKey: "aiProvider") ?? "anthropic"
        let provider = AIProvider(rawValue: providerRaw) ?? .anthropic
        let mainModel = AIModelCatalog.mainModel

        // No trajector settings at all means the main model also runs on
        // foundation IDs, so Haiku's foundation ID is equally reachable. So
        // is it on a non-master account, where the ARNs never apply.
        let account = AIAccountSettings.resolved(for: .frameAnalysis)
        let trajector = account.isMaster ? TrajectorSettings.load() : nil
        let choice = frameAnalysisModel(
            preferred: ScreenShareSettings.frameAnalysisModel,
            mainModel: mainModel,
            provider: provider,
            haikuProfileAvailable: trajector == nil || trajector?.haikuModel != nil
        )
        if choice.fellBackToMainModel {
            LogManager.send("Frame analysis using main model \(mainModel): no Haiku inference profile in trajector settings", category: .screen)
        }
        return try await makeClient(provider: provider, model: choice.model, account: account)
    }

    /// Haiku, for small high-volume text jobs like sorting topics into
    /// kinds. Falls back to the main model on a Bedrock org with no Haiku
    /// inference profile, as frame analysis does.
    static func makeLightClient() async throws -> (any AIClient)? {
        let providerRaw = UserDefaults.standard.string(forKey: "aiProvider") ?? "anthropic"
        let provider = AIProvider(rawValue: providerRaw) ?? .anthropic
        let trajector = TrajectorSettings.load()
        let choice = frameAnalysisModel(
            preferred: AIModelCatalog.haiku,
            mainModel: AIModelCatalog.mainModel,
            provider: provider,
            haikuProfileAvailable: trajector == nil || trajector?.haikuModel != nil
        )
        return try await makeClient(provider: provider, model: choice.model)
    }

    /// Resolution of which model the frame-analysis client is bound to.
    struct FrameAnalysisModelChoice: Equatable {
        let model: String
        let fellBackToMainModel: Bool
    }

    /// Pure resolver for the frame-analysis model. An empty preference means
    /// "same as main model". Bedrock orgs that route through inference
    /// profiles can't invoke a model without a mapped profile — when Haiku
    /// has no slot, fall back to the main model instead of failing mid-meeting.
    static func frameAnalysisModel(
        preferred: String,
        mainModel: String,
        provider: AIProvider,
        haikuProfileAvailable: Bool
    ) -> FrameAnalysisModelChoice {
        guard !preferred.isEmpty, preferred != mainModel else {
            return FrameAnalysisModelChoice(model: mainModel, fellBackToMainModel: false)
        }
        if provider == .bedrock, preferred.contains("haiku"), !haikuProfileAvailable {
            return FrameAnalysisModelChoice(model: mainModel, fellBackToMainModel: true)
        }
        return FrameAnalysisModelChoice(model: preferred, fellBackToMainModel: false)
    }

    /// `account` is the AWS account a Bedrock client bills to — the master
    /// from Settings → AI unless a feature slot overrides it.
    private static func makeClient(
        provider: AIProvider,
        model: String,
        account: ResolvedAIAccount = AIAccountSettings.master()
    ) async throws -> (any AIClient)? {
        switch provider {
        case .anthropic:
            guard let apiKey = try KeychainHelper.get(AIPromptTemplates.keychainKey),
                  !apiKey.isEmpty else {
                return nil
            }
            return ClaudeAPIClient(apiKey: apiKey, model: model)

        case .bedrock:
            AWSCredentialLoader.restoreAccess()
            let credentials = try await AWSCredentialLoader.loadCredentials(profile: account.profile)
            let bedrockModel = resolveBedrockModel(for: model, useInferenceProfiles: account.isMaster)
            return BedrockAPIClient(credentials: credentials, region: account.region, model: bedrockModel)
        }
    }

    /// Resolve model: prefer inference profile ARN from trajector settings, fall back to foundation model ID.
    ///
    /// The ARNs in trajector-settings.json belong to the master account; a
    /// slot pointed at another account can't invoke them, so it calls the
    /// foundation id instead.
    static func resolveBedrockModel(for anthropicModel: String, useInferenceProfiles: Bool = true) -> String {
        let settings = useInferenceProfiles ? TrajectorSettings.load() : nil
        let model = AIModelCatalog.canonical(anthropicModel)

        // Map the UI model choice to the corresponding inference profile ARN
        switch model {
        case AIModelCatalog.opus:
            if let arn = settings?.opusModel { return arn }
        case AIModelCatalog.sonnet:
            if let arn = settings?.sonnetModel { return arn }
        case AIModelCatalog.haiku:
            if let arn = settings?.haikuModel { return arn }
        default:
            break
        }

        // Fall back to foundation model ID
        return foundationModelId(for: model)
    }

    /// Bedrock model ID when no inference profile is configured. The 5-series
    /// has no ARN-versioned `-v1:0` form on Bedrock — InvokeModel takes the
    /// `anthropic.`-prefixed alias. Haiku 4.5 keeps its dated ID and needs a
    /// cross-region prefix: the bare ID 400s on on-demand throughput.
    static func foundationModelId(for anthropicModel: String) -> String {
        switch AIModelCatalog.canonical(anthropicModel) {
        case AIModelCatalog.opus:
            "anthropic.claude-opus-5"
        case AIModelCatalog.sonnet:
            "anthropic.claude-sonnet-5"
        case AIModelCatalog.haiku:
            "global.anthropic.claude-haiku-4-5-20251001-v1:0"
        default:
            "anthropic.\(anthropicModel)"
        }
    }
}

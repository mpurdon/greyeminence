import SwiftUI
import SwiftData

/// Settings → AI → Screen-frame analysis: which model describes captured
/// frames, and which account it bills to. Whether frames are analysed at
/// all, and how often, stays with the capture settings in Screen Share.
struct FrameAnalysisModelSection: View {
    let profiles: [AWSCredentialLoader.ProfileInfo]
    let isBedrock: Bool

    @AppStorage(ScreenShareSettings.frameAnalysisModelKey) private var frameAnalysisModel = ScreenShareSettings.defaultFrameAnalysisModel
    @AppStorage(ScreenShareSettings.analysisEnabledKey) private var analysisEnabled = true
    private var navigation = SettingsNavigation.shared

    init(profiles: [AWSCredentialLoader.ProfileInfo], isBedrock: Bool) {
        self.profiles = profiles
        self.isBedrock = isBedrock
    }

    var body: some View {
        Section {
            Picker("Model", selection: $frameAnalysisModel) {
                Text("Haiku 4.5 (recommended)").tag(ScreenShareSettings.defaultFrameAnalysisModel)
                Text("Same as meeting analysis").tag("")
            }
            Text("Haiku describes frames at a fraction of the main model's cost. Meeting summaries and session recaps always use the meeting-analysis model.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isBedrock {
                AIAccountPicker(slot: .frameAnalysis, profiles: profiles)
            }

            HStack(spacing: 4) {
                Text(analysisEnabled ? "Frame analysis is on." : "Frame analysis is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Capture and analysis settings are in Screen Share") {
                    navigation.pane = .screenShare
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } header: {
            Label("Screen-frame analysis", systemImage: "rectangle.dashed.badge.record")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }
}

/// Settings → AI → Search embeddings: the embedding method behind Ask, and
/// for the Bedrock methods the account, optional inference-profile ARN and a
/// one-string connection test. Index status and the rebuild live in Ask;
/// switching methods here offers the rebuild because until it runs, Ask
/// searches an index the new method hasn't written to.
struct EmbeddingModelSection: View {
    let profiles: [AWSCredentialLoader.ProfileInfo]
    var onRefreshProfiles: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @AppStorage("embeddingProvider") private var embeddingProviderRaw = EmbeddingProvider.nlEmbedding.rawValue
    @State private var showReindexPrompt = false
    @State private var previousProviderRaw: String?
    @State private var isTesting = false
    @State private var test: TestResult?
    private var reindex = EmbeddingReindexController.shared
    private var navigation = SettingsNavigation.shared

    enum TestResult {
        case success(String)
        case failure(String)
    }

    init(profiles: [AWSCredentialLoader.ProfileInfo], onRefreshProfiles: @escaping () -> Void) {
        self.profiles = profiles
        self.onRefreshProfiles = onRefreshProfiles
    }

    private var provider: EmbeddingProvider {
        EmbeddingProvider(rawValue: embeddingProviderRaw) ?? .nlEmbedding
    }

    private var isBedrockMethod: Bool {
        provider == .titan || provider == .cohere
    }

    var body: some View {
        Section {
            Picker("Method", selection: $embeddingProviderRaw) {
                ForEach(EmbeddingProvider.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .onChange(of: embeddingProviderRaw) { previous, _ in
                // Vectors from different models aren't comparable, and a
                // search only consults records embedded by the current one
                // — so until the index is rebuilt, Ask finds nothing. Say so
                // at the moment of the switch rather than letting it look
                // like the search broke.
                previousProviderRaw = previous
                test = nil
                reindex.refreshCounts()
                showReindexPrompt = reindex.coverage.indexed == 0
            }

            Text(provider.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !provider.isAvailable {
                Label(provider.unavailableReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isBedrockMethod {
                AIAccountPicker(slot: .embeddings, profiles: profiles) { test = nil }

                // Blank is the common case; an org that scopes its role to
                // profile ARNs cannot invoke the bare foundation id at all,
                // and gets a 403 that names the foundation model rather than
                // the missing profile.
                TextField(
                    "Inference profile ARN",
                    text: bedrockARNBinding,
                    prompt: Text("Optional — leave blank to call the model directly")
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())

                HStack(spacing: 8) {
                    Button(isTesting ? "Testing…" : "Test connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isTesting)

                    Button {
                        // ~/.aws is edited outside this app — by the AWS CLI,
                        // by a credential manager, by hand — so the list has
                        // to be re-readable without relaunching.
                        onRefreshProfiles()
                        test = nil
                    } label: {
                        Label("Refresh profiles", systemImage: "arrow.clockwise")
                    }
                    .help("Re-read ~/.aws/config and ~/.aws/credentials")

                    switch test {
                    case .success(let detail):
                        Label(detail, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .failure(let detail):
                        VStack(alignment: .leading, spacing: 2) {
                            Label(detail, systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                            Button("What this means") {
                                openWindow(id: "help-doc", value: HelpDoc.search)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    case nil:
                        Text("Embeds one short string. Confirms the account can invoke the model before you commit to a full rebuild.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 4) {
                Text("Indexed with this method: \(reindex.coverage.label).")
                    .font(.caption)
                    .foregroundStyle(reindex.coverage.indexed == 0 ? .orange : .secondary)
                Button("Index status and rebuild are in Ask") {
                    navigation.pane = .ask
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } header: {
            Label("Search embeddings", systemImage: "sparkle.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
        .onAppear { reindex.refreshCounts() }
        .alert("Rebuild the search index?", isPresented: $showReindexPrompt) {
            Button("Rebuild now") {
                Task { await reindex.reindexAll(modelContext: modelContext) }
                navigation.pane = .ask
            }
            Button("Switch back", role: .cancel) {
                if let previousProviderRaw { embeddingProviderRaw = previousProviderRaw }
                reindex.refreshCounts()
            }
            Button("Later", role: .destructive) {}
        } message: {
            Text("\(provider.shortLabel) hasn't indexed anything yet, and Ask only searches what the selected method produced — until it's rebuilt, questions will come back empty.\n\n\(rebuildEstimate)")
        }
    }

    /// What rebuilding actually entails, in the terms someone deciding would
    /// want: how long, and whether it costs money.
    private var rebuildEstimate: String {
        switch provider {
        case .nlEmbedding:
            "Runs on-device: no network, no cost, a few minutes."
        case .titan:
            "Runs through Bedrock on the account selected above. Roughly 5.4M tokens for a full index — about a dime at Titan's rate — but one request per chunk, so tens of thousands of round trips. Test the connection first."
        case .cohere:
            "Runs through Bedrock on the account selected above, 96 chunks per request — a few hundred round trips rather than tens of thousands. Roughly 5.4M tokens for a full index, about fifty cents. Test the connection first."
        case .voyage:
            "Not available."
        }
    }

    /// Per-provider, so switching methods doesn't hand one model's ARN to
    /// another. Reads and writes `UserDefaults` directly because the key
    /// depends on the current selection, which `@AppStorage` can't express.
    private var bedrockARNBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: BedrockEmbeddingAccount.arnKey(for: provider)) ?? "" },
            set: { newValue in
                let key = BedrockEmbeddingAccount.arnKey(for: provider)
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    UserDefaults.standard.removeObject(forKey: key)
                } else {
                    UserDefaults.standard.set(trimmed, forKey: key)
                }
                test = nil
            }
        )
    }

    @MainActor
    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        // Test whatever is actually selected, not a hard-coded model.
        let service = provider.makeService()
        let account = BedrockEmbeddingAccount.resolved(region: nil, profile: nil)
        let where_ = "\(account.profile) · \(account.region)"
        guard service.isAvailable else {
            test = .failure("No AWS profiles this app can authenticate as.")
            return
        }
        // Catch an unusable profile before spending a request on it — most
        // often the inherited one, when the main AI account is something the
        // loader can't follow either.
        if let info = profiles.first(where: { $0.name == account.profile }), !info.isSupported {
            test = .failure("Profile \(info.name) \(info.kind.reason).")
            return
        }
        // Go through the credential loader directly first: it names the cause
        // (expired token, blocked helper) where the embed call can only say it
        // failed.
        do {
            AWSCredentialLoader.restoreAccess()
            _ = try await AWSCredentialLoader.loadCredentials(profile: account.profile)
        } catch {
            test = .failure(error.localizedDescription)
            return
        }

        if let vector = await service.embedDocument("Grey Eminence search index probe") {
            let invoked = BedrockEmbeddingAccount.modelID(
                for: provider,
                foundation: provider.makeService().modelIdentifier
            )
            let viaProfile = invoked.hasPrefix("arn:") ? " via inference profile" : ""
            test = .success("\(vector.count)-dim vector from \(where_)\(viaProfile)")
        } else {
            let reason = service.lastFailureDescription.map { " — \($0)" } ?? " — see the Activity Log for the exact error"
            test = .failure("Couldn't embed with \(where_)\(reason).")
        }
    }
}

import Foundation

/// What an embedding is *for*. Retrieval models are trained asymmetrically —
/// the same sentence embeds differently as a stored document than as a search
/// query — and Cohere requires the distinction explicitly. Getting it wrong
/// costs recall silently, which is why it's a parameter rather than a default.
enum EmbeddingPurpose: String, Sendable {
    case document
    case query
}

/// Shared Bedrock plumbing for embedding models: credentials, signing, retry,
/// and the adaptive concurrency limit.
///
/// Factored out when a second model arrived. The models differ only in their
/// request and response shape — everything hard about talking to Bedrock is
/// identical, and duplicating the throttle handling would mean two places to
/// get backoff wrong.
actor BedrockEmbeddingTransport {
    private let region: String
    private let profile: String
    private var cached: AWSCredentials?
    private var inFlightLoad: Task<AWSCredentials, Error>?

    /// Attempts per request. Throttling is transient, and a dropped record is
    /// invisible damage — the meeting still looks indexed.
    static let maxAttempts = 6

    /// Shared by every embedding request in the process, so the fan-out
    /// narrows as a whole when the account's quota is reached.
    private static let limiter = AdaptiveConcurrencyLimiter(start: 4, ceiling: 12)
    private static let throttleGate = ThrottleGate()

    init(region: String, profile: String) {
        self.region = region
        self.profile = profile
    }

    /// One successful invoke: the response body plus the billed input
    /// tokens, which Bedrock reports in a response header rather than in
    /// the body for models (Cohere) whose body carries none.
    struct Response: Sendable {
        let data: Data
        let inputTokens: Int?
    }

    static let inputTokenHeader = "x-amzn-bedrock-input-token-count"

    /// POST `body` to a model's invoke endpoint, retrying throttles.
    func invoke(modelID: String, body: Data) async throws -> Response {
        var lastError: Error = BedrockAPIError.invalidResponse
        for attempt in 0..<Self.maxAttempts {
            try Task.checkCancellation()
            await Self.throttleGate.waitUntilOpen()
            await Self.limiter.acquire()
            do {
                let response = try await send(modelID: modelID, body: body, allowingRefresh: attempt == 0)
                await Self.limiter.release(throttled: false)
                return response
            } catch let error as BedrockAPIError {
                guard case .httpError(let status, _) = error, Self.isTransient(status) else {
                    await Self.limiter.release(throttled: false)
                    throw error
                }
                // Narrow the fan-out AND pause it. Backing off without
                // narrowing re-runs the same request rate a moment later.
                await Self.limiter.release(throttled: true)
                lastError = error
                guard attempt < Self.maxAttempts - 1 else { break }
                let delay = Self.backoffSeconds(attempt: attempt)
                await Self.throttleGate.close(forSeconds: delay)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                await Self.limiter.release(throttled: false)
                throw error
            }
        }
        throw lastError
    }

    private func send(modelID: String, body: Data, allowingRefresh: Bool) async throws -> Response {
        let credentials = try await credentials()
        let path = "/model/\(AWSSigV4Signer.encodeSegment(modelID))/invoke"
        let host = "bedrock-runtime.\(region).amazonaws.com"
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw BedrockAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 120
        request = AWSSigV4Signer(credentials: credentials, region: region)
            .sign(request: request, body: body, host: host, path: path)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BedrockAPIError.invalidResponse
        }
        // Expired session — refresh once, then give up, so a stale credential
        // can't spin a whole reindex.
        if (http.statusCode == 403 || http.statusCode == 401), allowingRefresh {
            cached = nil
            return try await send(modelID: modelID, body: body, allowingRefresh: false)
        }
        guard (200...299).contains(http.statusCode) else {
            throw BedrockAPIError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }
        let tokens = http.value(forHTTPHeaderField: Self.inputTokenHeader).flatMap { Int($0) }
        return Response(data: data, inputTokens: tokens)
    }

    /// One credential fetch even when a dozen requests start at once.
    private func credentials() async throws -> AWSCredentials {
        if let cached { return cached }
        if let inFlightLoad { return try await inFlightLoad.value }
        let task = Task<AWSCredentials, Error> {
            AWSCredentialLoader.restoreAccess()
            return try await AWSCredentialLoader.loadCredentials(profile: profile)
        }
        inFlightLoad = task
        defer { inFlightLoad = nil }
        let loaded = try await task.value
        cached = loaded
        return loaded
    }

    /// 429 is throttling; 500/503 are Bedrock shedding load. Anything else —
    /// a denied action, a malformed body — fails identically forever, so
    /// retrying only delays the report.
    nonisolated static func isTransient(_ status: Int) -> Bool {
        status == 429 || status == 500 || status == 503
    }

    /// 0.5s, 1s, 2s, 4s, 8s … each ±25%. Jitter matters as much as the
    /// backoff: without it, workers throttled together retry together and stay
    /// in lockstep.
    nonisolated static func backoffSeconds(attempt: Int, jitter: Double = Double.random(in: 0.75...1.25)) -> Double {
        min(30, 0.5 * pow(2, Double(attempt))) * jitter
    }

    /// Holds every worker back until a shared deadline passes.
    private actor ThrottleGate {
        private var openAt = Date.distantPast

        func waitUntilOpen() async {
            while true {
                let remaining = openAt.timeIntervalSinceNow
                guard remaining > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }

        /// Never shortens an existing pause — a worker on its first retry must
        /// not release one that has backed off much further.
        func close(forSeconds seconds: Double) {
            let candidate = Date().addingTimeInterval(seconds)
            if candidate > openAt { openAt = candidate }
        }
    }
}

/// Where an embedding service reads its AWS account from.
///
/// Its own profile because it need not be the analysis account: a role scoped
/// to the Anthropic models can't invoke an embedding model at all, and a
/// second account is usually the answer. Blank follows Settings → AI.
enum BedrockEmbeddingAccount {
    static let profileKey = "embeddingAWSProfile"
    static let regionKey = "embeddingAWSRegion"

    static func resolved(region: String?, profile: String?) -> (region: String, profile: String) {
        let defaults = UserDefaults.standard
        let resolvedRegion = region
            ?? nonEmpty(defaults.string(forKey: regionKey))
            ?? nonEmpty(defaults.string(forKey: "awsRegion"))
            ?? "us-east-1"
        let resolvedProfile = profile
            ?? nonEmpty(defaults.string(forKey: profileKey))
            ?? nonEmpty(defaults.string(forKey: "awsProfile"))
            ?? "default"
        return (resolvedRegion, resolvedProfile)
    }

    /// Which model id to invoke for `provider`.
    ///
    /// An org that routes Bedrock through application inference profiles can't
    /// invoke a foundation model directly — the role is scoped to the profile
    /// ARNs, so the bare id 403s. Resolution order mirrors the Claude clients:
    /// an ARN set in Settings wins, then one published in the shared Claude
    /// settings file, then the foundation id for accounts with direct access.
    static func modelID(for provider: EmbeddingProvider, foundation: String) -> String {
        if let override = nonEmpty(UserDefaults.standard.string(forKey: arnKey(for: provider))) {
            return override
        }
        let settings = TrajectorSettings.load()
        let published: String?
        switch provider {
        case .titan: published = settings?.titanEmbedModel
        case .cohere: published = settings?.cohereEmbedModel
        case .nlEmbedding, .voyage: published = nil
        }
        return nonEmpty(published) ?? foundation
    }

    /// Per-provider so switching methods doesn't invoke one model's ARN for
    /// another's — they are not interchangeable, and the failure would be a
    /// confusing validation error rather than an obvious misconfiguration.
    static func arnKey(for provider: EmbeddingProvider) -> String {
        "embeddingModelARN.\(provider.rawValue)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

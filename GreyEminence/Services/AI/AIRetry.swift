import Foundation

/// Retry policy for transient AI failures.
///
/// Rate limits, overload errors, and network timeouts are transient — the right
/// thing to do is wait briefly and try again rather than burn the whole 45s
/// analysis cycle. Non-transient failures (auth, bad request, parser errors)
/// should propagate immediately so we don't mask real bugs.
///
/// The exact backoff schedule is tuned for Claude's rate-limit behavior:
/// attempt 1 immediate, attempt 2 after 2s, attempt 3 after 6s. Total worst-
/// case wait is ~8s, well within the 90s per-call timeout wrapping.
enum AIRetry {
    /// Maximum number of attempts (initial attempt + retries).
    static let maxAttempts: Int = 3

    /// Delays between attempts in seconds. Must have `maxAttempts - 1` entries.
    static let backoffSeconds: [Double] = [2, 6]

    /// Run `operation`, retrying on transient errors per the policy above.
    /// Non-retryable errors bubble immediately. Logs each retry so the user
    /// can see in the activity log what happened.
    static func run<T: Sendable>(
        label: String,
        meetingID: UUID? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard isRetryable(error), attempt < maxAttempts - 1 else {
                    throw error
                }
                let delay = backoffSeconds[attempt]
                LogManager.send(
                    "AI \(label) transient failure (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription) — retrying in \(delay)s",
                    category: .ai,
                    level: .warning,
                    meetingID: meetingID
                )
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        // Unreachable in practice — the last attempt either returns or throws
        // above. The force-unwrap keeps the type system happy without a
        // bogus fallback value.
        throw lastError ?? CancellationError()
    }

    /// Classifier for known transient errors. Stays conservative: anything
    /// not explicitly recognized is treated as non-retryable so we don't mask
    /// real bugs by silently retrying them.
    static func isRetryable(_ error: Error) -> Bool {
        // URLSession network errors
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .resourceUnavailable:
                return true
            default:
                return false
            }
        }

        // Claude API
        if let claude = error as? ClaudeAPIError {
            switch claude {
            case .httpError(let statusCode),
                 .apiError(let statusCode, _):
                return isRetryableStatusCode(statusCode)
            default:
                return false
            }
        }

        // Bedrock API
        if let bedrock = error as? BedrockAPIError {
            switch bedrock {
            case .httpError(let statusCode, _):
                return isRetryableStatusCode(statusCode)
            default:
                return false
            }
        }

        // Our own timeout wrapper
        if error is AITimeoutError {
            return true
        }

        return false
    }

    private static func isRetryableStatusCode(_ code: Int) -> Bool {
        switch code {
        case 408,  // request timeout
             429,  // rate limit
             500,  // internal server error
             502,  // bad gateway
             503,  // service unavailable
             504,  // gateway timeout
             529:  // overloaded (Anthropic-specific)
            return true
        default:
            return false
        }
    }
}

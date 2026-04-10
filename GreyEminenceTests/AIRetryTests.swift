import XCTest
@testable import Grey_Eminence

/// Tests for the retry policy classifier. The actual `run()` function is
/// exercised via integration tests / real API calls — here we only verify the
/// pure classification logic so a future code change doesn't accidentally
/// retry things like auth failures or bad JSON.
final class AIRetryTests: XCTestCase {

    // MARK: - URLError classification

    func test_urlError_timedOut_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(URLError(.timedOut)))
    }

    func test_urlError_networkLost_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(URLError(.networkConnectionLost)))
    }

    func test_urlError_notConnected_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(URLError(.notConnectedToInternet)))
    }

    func test_urlError_cannotConnectToHost_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(URLError(.cannotConnectToHost)))
    }

    func test_urlError_badURL_isNotRetryable() {
        XCTAssertFalse(AIRetry.isRetryable(URLError(.badURL)))
    }

    func test_urlError_userCancelled_isNotRetryable() {
        XCTAssertFalse(AIRetry.isRetryable(URLError(.cancelled)))
    }

    // MARK: - ClaudeAPIError classification

    func test_claude_rateLimit_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(ClaudeAPIError.httpError(statusCode: 429)))
    }

    func test_claude_overloaded_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(ClaudeAPIError.httpError(statusCode: 529)))
    }

    func test_claude_internalServerError_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(ClaudeAPIError.httpError(statusCode: 500)))
    }

    func test_claude_badGateway_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(ClaudeAPIError.httpError(statusCode: 502)))
    }

    func test_claude_serviceUnavailable_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(ClaudeAPIError.httpError(statusCode: 503)))
    }

    func test_claude_gatewayTimeout_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(ClaudeAPIError.httpError(statusCode: 504)))
    }

    func test_claude_unauthorized_isNotRetryable() {
        // 401 is not retryable — the user needs to fix their API key.
        XCTAssertFalse(AIRetry.isRetryable(ClaudeAPIError.httpError(statusCode: 401)))
    }

    func test_claude_forbidden_isNotRetryable() {
        XCTAssertFalse(AIRetry.isRetryable(ClaudeAPIError.httpError(statusCode: 403)))
    }

    func test_claude_badRequest_isNotRetryable() {
        XCTAssertFalse(AIRetry.isRetryable(ClaudeAPIError.httpError(statusCode: 400)))
    }

    func test_claude_apiError_alsoCheckedByStatus() {
        // apiError and httpError should be treated symmetrically.
        XCTAssertTrue(AIRetry.isRetryable(ClaudeAPIError.apiError(statusCode: 429, message: "rate limited")))
        XCTAssertFalse(AIRetry.isRetryable(ClaudeAPIError.apiError(statusCode: 401, message: "bad key")))
    }

    func test_claude_noTextContent_isNotRetryable() {
        // Empty response means the model returned nothing — retrying will
        // almost certainly return nothing again.
        XCTAssertFalse(AIRetry.isRetryable(ClaudeAPIError.noTextContent))
    }

    func test_claude_invalidURL_isNotRetryable() {
        XCTAssertFalse(AIRetry.isRetryable(ClaudeAPIError.invalidURL))
    }

    // MARK: - BedrockAPIError classification

    func test_bedrock_rateLimit_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(BedrockAPIError.httpError(statusCode: 429, body: "")))
    }

    func test_bedrock_overloaded_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(BedrockAPIError.httpError(statusCode: 529, body: "")))
    }

    func test_bedrock_unauthorized_isNotRetryable() {
        XCTAssertFalse(AIRetry.isRetryable(BedrockAPIError.httpError(statusCode: 401, body: "")))
    }

    // MARK: - AITimeoutError

    func test_aiTimeout_isRetryable() {
        XCTAssertTrue(AIRetry.isRetryable(AITimeoutError.timedOut(seconds: 90)))
    }

    // MARK: - Unknown errors

    func test_unknownError_isNotRetryable() {
        // The classifier is conservative: unknown errors should NOT be retried,
        // to avoid masking real bugs by silently retrying them.
        struct FakeError: Error {}
        XCTAssertFalse(AIRetry.isRetryable(FakeError()))
    }
}

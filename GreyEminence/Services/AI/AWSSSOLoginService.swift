import AppKit
import CryptoKit
import Foundation

enum AWSSSOLoginService {

    struct SSOLoginResult {
        let accessToken: String
        let expiresAt: Date
    }

    /// Run the full SSO OIDC device authorization flow:
    /// 1. Register a public client
    /// 2. Start device authorization (opens browser)
    /// 3. Poll for token until user completes login
    /// 4. Cache the token to ~/.aws/sso/cache/
    static func login(config: SSOProfileConfig) async throws -> SSOLoginResult {
        let ssoRegion = config.ssoRegion
        let startUrl = config.startUrl

        // Step 1: Register client
        let registration = try await registerClient(region: ssoRegion)

        // Step 2: Start device authorization
        let deviceAuth = try await startDeviceAuthorization(
            region: ssoRegion,
            clientId: registration.clientId,
            clientSecret: registration.clientSecret,
            startUrl: startUrl
        )

        // Step 3: Open browser for user to authenticate
        if let url = URL(string: deviceAuth.verificationUriComplete) {
            await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }

        // Step 4: Poll for token
        let token = try await pollForToken(
            region: ssoRegion,
            clientId: registration.clientId,
            clientSecret: registration.clientSecret,
            deviceCode: deviceAuth.deviceCode,
            interval: deviceAuth.interval,
            expiresIn: deviceAuth.expiresIn
        )

        let expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))

        // Step 5: Cache the token
        cacheToken(
            accessToken: token.accessToken,
            expiresAt: expiresAt,
            region: ssoRegion,
            startUrl: startUrl,
            sessionName: config.sessionName
        )

        return SSOLoginResult(accessToken: token.accessToken, expiresAt: expiresAt)
    }

    // MARK: - OIDC API Calls

    private struct ClientRegistration {
        let clientId: String
        let clientSecret: String
    }

    private static func registerClient(region: String) async throws -> ClientRegistration {
        let url = URL(string: "https://oidc.\(region).amazonaws.com/client/register")!
        let body: [String: Any] = [
            "clientName": "Grey Eminence",
            "clientType": "public",
        ]

        let data = try await postJSON(url: url, body: body)

        guard let clientId = data["clientId"] as? String,
              let clientSecret = data["clientSecret"] as? String else {
            throw SSOLoginError.registrationFailed
        }

        return ClientRegistration(clientId: clientId, clientSecret: clientSecret)
    }

    private struct DeviceAuthorization {
        let deviceCode: String
        let verificationUriComplete: String
        let interval: Int
        let expiresIn: Int
    }

    private static func startDeviceAuthorization(
        region: String,
        clientId: String,
        clientSecret: String,
        startUrl: String
    ) async throws -> DeviceAuthorization {
        let url = URL(string: "https://oidc.\(region).amazonaws.com/device_authorization")!
        let body: [String: Any] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "startUrl": startUrl,
        ]

        let data = try await postJSON(url: url, body: body)

        guard let deviceCode = data["deviceCode"] as? String,
              let verificationUriComplete = data["verificationUriComplete"] as? String else {
            throw SSOLoginError.deviceAuthFailed
        }

        let interval = data["interval"] as? Int ?? 5
        let expiresIn = data["expiresIn"] as? Int ?? 600

        return DeviceAuthorization(
            deviceCode: deviceCode,
            verificationUriComplete: verificationUriComplete,
            interval: interval,
            expiresIn: expiresIn
        )
    }

    private struct TokenResponse {
        let accessToken: String
        let expiresIn: Int
    }

    private static func pollForToken(
        region: String,
        clientId: String,
        clientSecret: String,
        deviceCode: String,
        interval: Int,
        expiresIn: Int
    ) async throws -> TokenResponse {
        let url = URL(string: "https://oidc.\(region).amazonaws.com/token")!
        let body: [String: Any] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "deviceCode": deviceCode,
            "grantType": "urn:ietf:params:oauth:grant-type:device_code",
        ]

        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        let pollInterval = UInt64(max(interval, 1)) * 1_000_000_000

        while Date() < deadline {
            try await Task.sleep(nanoseconds: pollInterval)

            guard !Task.isCancelled else {
                throw CancellationError()
            }

            do {
                let data = try await postJSON(url: url, body: body)
                if let accessToken = data["accessToken"] as? String {
                    let expiresIn = data["expiresIn"] as? Int ?? 28800
                    return TokenResponse(accessToken: accessToken, expiresIn: expiresIn)
                }
            } catch SSOLoginError.authorizationPending {
                continue
            } catch SSOLoginError.slowDown {
                try await Task.sleep(nanoseconds: pollInterval)
                continue
            }
        }

        throw SSOLoginError.loginTimedOut
    }

    // MARK: - Token Cache

    private static func cacheToken(
        accessToken: String,
        expiresAt: Date,
        region: String,
        startUrl: String,
        sessionName: String?
    ) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let expiresAtString = df.string(from: expiresAt)

        let cacheKeySource = sessionName ?? startUrl
        let hash = cacheKeySource.utf8.reduce(into: Data()) { $0.append(contentsOf: [$1]) }
        let sha1 = sha1Hex(hash)
        let cacheFileName = "\(sha1).json"

        let cacheData: [String: Any] = [
            "accessToken": accessToken,
            "expiresAt": expiresAtString,
            "region": region,
            "startUrl": startUrl,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: cacheData, options: [.prettyPrinted]) else {
            return
        }

        // Try bookmarked ~/.aws directory first
        let cacheDir: URL
        if let dirURL = AWSCredentialLoader.restoreAccess() {
            cacheDir = dirURL.appendingPathComponent("sso/cache")
        } else {
            cacheDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".aws/sso/cache")
        }

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheFile = cacheDir.appendingPathComponent(cacheFileName)
        try? jsonData.write(to: cacheFile)
    }

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HTTP Helper

    private static func postJSON(url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SSOLoginError.networkError("Invalid response")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SSOLoginError.networkError("Invalid JSON")
        }

        if httpResponse.statusCode == 400 {
            let errorCode = json["error"] as? String ?? ""
            if errorCode == "authorization_pending" {
                throw SSOLoginError.authorizationPending
            }
            if errorCode == "slow_down" {
                throw SSOLoginError.slowDown
            }
            let message = json["error_description"] as? String ?? errorCode
            throw SSOLoginError.networkError(message)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = json["error_description"] as? String ?? "HTTP \(httpResponse.statusCode)"
            throw SSOLoginError.networkError(message)
        }

        return json
    }
}

enum SSOLoginError: LocalizedError {
    case registrationFailed
    case deviceAuthFailed
    case authorizationPending
    case slowDown
    case loginTimedOut
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .registrationFailed:
            "Failed to register SSO client"
        case .deviceAuthFailed:
            "Failed to start device authorization"
        case .authorizationPending:
            "Waiting for browser authentication"
        case .slowDown:
            "Rate limited, slowing down"
        case .loginTimedOut:
            "SSO login timed out — try again"
        case .networkError(let message):
            "SSO error: \(message)"
        }
    }
}

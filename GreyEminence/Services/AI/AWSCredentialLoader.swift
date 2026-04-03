import CryptoKit
import Foundation

struct AWSCredentials: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
}

struct SSOProfileConfig {
    let startUrl: String
    let ssoRegion: String
    let accountId: String
    let roleName: String
    let sessionName: String?
}

enum AWSCredentialLoader {
    private static let bookmarkKey = "awsDirectoryBookmark"

    // MARK: - Security-Scoped Bookmark

    static func persistAccess(to directoryURL: URL) {
        if let data = try? directoryURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    @discardableResult
    static func restoreAccess() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            // Bookmark can't be resolved — clear it so UI shows "Locate" prompt
            clearBookmark()
            return nil
        }

        let didAccess = url.startAccessingSecurityScopedResource()

        if isStale || !didAccess {
            // Try to re-create the bookmark from the resolved URL
            persistAccess(to: url)
        }

        return didAccess ? url : nil
    }

    static var hasBookmark: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    static func clearBookmark() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    // MARK: - Credential Loading

    static func loadCredentials(profile: String) async throws -> AWSCredentials {
        // Check if this is an SSO profile first
        if let ssoConfig = parseSSOConfig(profile: profile) {
            return try await loadSSOCredentials(config: ssoConfig)
        }

        // Fall back to static credentials from ~/.aws/credentials
        return try loadStaticCredentials(profile: profile)
    }

    static func loadRegion(profile: String) -> String? {
        guard let configURL = try? resolveConfigFile(),
              let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        let parsed = parseINI(content)
        let sectionName = profile == "default" ? "default" : "profile \(profile)"
        return parsed[sectionName]?["region"]
    }

    static func availableProfiles() -> [String] {
        guard let configURL = try? resolveConfigFile(),
              let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return []
        }

        return parseINI(content).keys.compactMap { key in
            if key == "default" { return key }
            if key.hasPrefix("profile ") { return String(key.dropFirst(8)) }
            return nil
        }.sorted()
    }

    // MARK: - Static Credentials

    private static func loadStaticCredentials(profile: String) throws -> AWSCredentials {
        let credentialsURL = try resolveCredentialsFile()
        let content = try String(contentsOf: credentialsURL, encoding: .utf8)
        let parsed = parseINI(content)

        guard let section = parsed[profile] else {
            throw AWSCredentialError.profileNotFound(profile)
        }

        guard let accessKey = section["aws_access_key_id"],
              let secretKey = section["aws_secret_access_key"] else {
            throw AWSCredentialError.missingCredentials(profile)
        }

        return AWSCredentials(
            accessKeyId: accessKey,
            secretAccessKey: secretKey,
            sessionToken: section["aws_session_token"]
        )
    }

    // MARK: - SSO

    static func parseSSOConfig(profile: String) -> SSOProfileConfig? {
        guard let configURL = try? resolveConfigFile(),
              let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        let parsed = parseINI(content)
        let sectionName = profile == "default" ? "default" : "profile \(profile)"

        guard let section = parsed[sectionName] else { return nil }

        // New format: sso_session reference
        if let sessionName = section["sso_session"],
           let ssoSession = parsed["sso-session \(sessionName)"],
           let startUrl = ssoSession["sso_start_url"],
           let ssoRegion = ssoSession["sso_region"],
           let accountId = section["sso_account_id"],
           let roleName = section["sso_role_name"] {
            return SSOProfileConfig(
                startUrl: startUrl,
                ssoRegion: ssoRegion,
                accountId: accountId,
                roleName: roleName,
                sessionName: sessionName
            )
        }

        // Legacy format: SSO fields directly in profile
        if let startUrl = section["sso_start_url"],
           let ssoRegion = section["sso_region"],
           let accountId = section["sso_account_id"],
           let roleName = section["sso_role_name"] {
            return SSOProfileConfig(
                startUrl: startUrl,
                ssoRegion: ssoRegion,
                accountId: accountId,
                roleName: roleName,
                sessionName: nil
            )
        }

        return nil
    }

    private static func loadSSOCredentials(config: SSOProfileConfig) async throws -> AWSCredentials {
        let token = try loadCachedSSOToken(config: config)
        return try await fetchRoleCredentials(config: config, accessToken: token)
    }

    private static func loadCachedSSOToken(config: SSOProfileConfig) throws -> String {
        // Cache key: SHA1 of session name (new format) or start URL (legacy)
        let cacheKeySource = config.sessionName ?? config.startUrl
        let hash = Insecure.SHA1.hash(data: Data(cacheKeySource.utf8))
        let cacheFileName = hash.map { String(format: "%02x", $0) }.joined() + ".json"

        let cacheFile: URL
        if let dirURL = restoreAccess() {
            cacheFile = dirURL.appendingPathComponent("sso/cache/\(cacheFileName)")
        } else {
            cacheFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".aws/sso/cache/\(cacheFileName)")
        }

        guard let data = try? Data(contentsOf: cacheFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["accessToken"] as? String else {
            throw AWSCredentialError.ssoTokenNotFound
        }

        // Check expiration
        if let expiresAt = json["expiresAt"] as? String {
            let formats = [
                "yyyy-MM-dd'T'HH:mm:ss'Z'",
                "yyyy-MM-dd'T'HH:mm:ss'UTC'",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            ]
            for format in formats {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(identifier: "UTC")
                df.dateFormat = format
                if let expiry = df.date(from: expiresAt), expiry < Date() {
                    throw AWSCredentialError.ssoTokenExpired
                }
            }
        }

        return accessToken
    }

    private static func fetchRoleCredentials(
        config: SSOProfileConfig,
        accessToken: String
    ) async throws -> AWSCredentials {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "portal.sso.\(config.ssoRegion).amazonaws.com"
        components.path = "/federation/credentials"
        components.queryItems = [
            URLQueryItem(name: "role_name", value: config.roleName),
            URLQueryItem(name: "account_id", value: config.accountId),
        ]

        guard let url = components.url else {
            throw AWSCredentialError.ssoFetchFailed("Invalid SSO URL")
        }

        var request = URLRequest(url: url)
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AWSCredentialError.ssoFetchFailed("HTTP \(statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roleCreds = json["roleCredentials"] as? [String: Any],
              let accessKeyId = roleCreds["accessKeyId"] as? String,
              let secretAccessKey = roleCreds["secretAccessKey"] as? String,
              let sessionToken = roleCreds["sessionToken"] as? String else {
            throw AWSCredentialError.ssoFetchFailed("Invalid response format")
        }

        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken
        )
    }

    // MARK: - File Resolution

    private static func resolveConfigFile() throws -> URL {
        if let dirURL = restoreAccess() {
            let configURL = dirURL.appendingPathComponent("config")
            if FileManager.default.fileExists(atPath: configURL.path) {
                return configURL
            }
        }

        let directPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/config")
        if FileManager.default.fileExists(atPath: directPath.path) {
            return directPath
        }

        throw AWSCredentialError.configFileNotFound
    }

    private static func resolveCredentialsFile() throws -> URL {
        if let dirURL = restoreAccess() {
            let credURL = dirURL.appendingPathComponent("credentials")
            if FileManager.default.fileExists(atPath: credURL.path) {
                return credURL
            }
        }

        let directPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/credentials")
        if FileManager.default.fileExists(atPath: directPath.path) {
            return directPath
        }

        throw AWSCredentialError.credentialsFileNotFound
    }

    // MARK: - INI Parser

    private static func parseINI(_ content: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var currentSection: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                if result[currentSection!] == nil {
                    result[currentSection!] = [:]
                }
                continue
            }

            if let section = currentSection,
               let eqIndex = trimmed.firstIndex(of: "=") {
                let key = trimmed[trimmed.startIndex..<eqIndex]
                    .trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eqIndex)...]
                    .trimmingCharacters(in: .whitespaces)
                result[section, default: [:]][key] = value
            }
        }

        return result
    }
}

enum AWSCredentialError: LocalizedError {
    case profileNotFound(String)
    case missingCredentials(String)
    case credentialsFileNotFound
    case configFileNotFound
    case ssoTokenNotFound
    case ssoTokenExpired
    case ssoFetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .profileNotFound(let profile):
            "AWS profile '\(profile)' not found"
        case .missingCredentials(let profile):
            "Missing access key or secret key in profile '\(profile)'"
        case .credentialsFileNotFound:
            "~/.aws/credentials not found — use 'Locate' to grant access"
        case .configFileNotFound:
            "~/.aws/config not found — use 'Locate' to grant access"
        case .ssoTokenNotFound:
            "SSO token not found — run 'aws sso login' first"
        case .ssoTokenExpired:
            "SSO token expired — run 'aws sso login' to refresh"
        case .ssoFetchFailed(let detail):
            "SSO credential fetch failed: \(detail)"
        }
    }
}

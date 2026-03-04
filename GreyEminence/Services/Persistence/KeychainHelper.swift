import Foundation
@preconcurrency import KeychainAccess

enum KeychainHelper {
    /// Data protection keychain — no password prompts for the owning app.
    private static let keychain = Keychain(service: "com.greyeminence.app")
        .accessibility(.afterFirstUnlockThisDeviceOnly)

    /// In-memory cache to avoid repeated keychain reads (which can trigger password prompts).
    private nonisolated(unsafe) static var cache: [String: String] = [:]

    static func get(_ key: String) throws -> String? {
        if let cached = cache[key] { return cached }
        let value = try keychain.get(key)
        if let value { cache[key] = value }
        return value
    }

    static func set(_ value: String, key: String) throws {
        try keychain.set(value, key: key)
        cache[key] = value
    }

    static func remove(_ key: String) throws {
        try keychain.remove(key)
        cache.removeValue(forKey: key)
    }
}

import Foundation

/// The Claude models the app offers, plus the mapping from IDs earlier builds
/// stored in UserDefaults. Model strings live here and nowhere else so a
/// generation bump is a one-file change.
enum AIModelCatalog {
    static let opus = "claude-opus-5"
    static let sonnet = "claude-sonnet-5"
    static let haiku = "claude-haiku-4-5"

    static let defaultMainModel = sonnet
    static let mainModelKey = "claudeModel"

    /// IDs written by builds before 0.33. Opus 4 and Sonnet 4 are deprecated
    /// on the direct API and retired/deprecated on Bedrock; the dated Haiku
    /// ID still works but the alias is the documented form.
    private static let legacyIDs: [String: String] = [
        "claude-opus-4-20250514": opus,
        "claude-sonnet-4-20250514": sonnet,
        "claude-haiku-4-5-20251001": haiku,
    ]

    /// Current ID for a possibly-legacy stored value. Unknown IDs pass
    /// through untouched so a hand-entered model still reaches the API.
    static func canonical(_ modelID: String) -> String {
        legacyIDs[modelID] ?? modelID
    }

    /// The user's main model, normalised. Every non-`@AppStorage` reader
    /// goes through here so a stale stored ID never reaches a request.
    static var mainModel: String {
        canonical(UserDefaults.standard.string(forKey: mainModelKey) ?? defaultMainModel)
    }

    /// Rewrite legacy IDs in place at launch. `@AppStorage` pickers bind to
    /// the raw stored string, so without this a user upgrading from an
    /// older build sees an empty Model picker until they re-select.
    static func migrateStoredDefaults(_ defaults: UserDefaults = .standard) {
        for key in [mainModelKey, ScreenShareSettings.frameAnalysisModelKey] {
            guard let stored = defaults.string(forKey: key),
                  let current = legacyIDs[stored] else { continue }
            defaults.set(current, forKey: key)
        }
    }
}

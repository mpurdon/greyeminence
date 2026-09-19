import Foundation

/// The AI features that can bill to their own AWS account.
///
/// Meeting analysis — and everything that rides on it: Ask answers,
/// interviews, prep, task tidy-up, report anchoring — uses the master
/// account from Settings → AI. These two are the ones with a reason to
/// differ: frame analysis runs a cheaper model that an org may host
/// elsewhere, and a role scoped to the Claude models usually can't invoke
/// an embedding model at all.
enum AIAccountSlot: String, CaseIterable, Identifiable, Sendable {
    case frameAnalysis
    case embeddings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .frameAnalysis: "Screen-frame analysis"
        case .embeddings: "Search embeddings"
        }
    }
}

/// Where a slot gets its credentials.
enum AIAccountChoice: Equatable, Sendable {
    /// Settings → AI's profile and region.
    case master
    /// Whatever the named slot resolves to, so two features stay on one
    /// account without naming it twice.
    case sameAs(AIAccountSlot)
    /// A specific `~/.aws` profile.
    case profile(String)

    /// Stored form: `master`, `sameAs:<slot>`, `profile:<name>`.
    var storedValue: String {
        switch self {
        case .master: "master"
        case .sameAs(let slot): "sameAs:\(slot.rawValue)"
        case .profile(let name): "profile:\(name)"
        }
    }

    init?(storedValue: String) {
        if storedValue == "master" {
            self = .master
        } else if storedValue.hasPrefix("sameAs:"),
                  let slot = AIAccountSlot(rawValue: String(storedValue.dropFirst("sameAs:".count))) {
            self = .sameAs(slot)
        } else if storedValue.hasPrefix("profile:") {
            let name = String(storedValue.dropFirst("profile:".count))
            guard !name.isEmpty else { return nil }
            self = .profile(name)
        } else {
            return nil
        }
    }
}

/// A slot's choice followed to an actual profile and region.
struct ResolvedAIAccount: Equatable, Sendable {
    let profile: String
    let region: String
    /// True when the chain ended at Settings → AI — the account whose
    /// inference-profile ARNs (trajector-settings.json) apply.
    let isMaster: Bool
}

/// Master account plus per-feature overrides, in UserDefaults.
///
/// Keys: `aiAccount.<slot>.choice` (see `AIAccountChoice.storedValue`) and
/// `aiAccount.<slot>.region` — empty means "the profile's own region, else
/// the master's". Missing choice means master.
enum AIAccountSettings {
    static let masterProfileKey = "awsProfile"
    static let masterRegionKey = "awsRegion"
    static let defaultProfile = "default"
    static let defaultRegion = "us-east-1"

    static func choiceKey(_ slot: AIAccountSlot) -> String { "aiAccount.\(slot.rawValue).choice" }
    static func regionKey(_ slot: AIAccountSlot) -> String { "aiAccount.\(slot.rawValue).region" }

    static func masterProfile(_ defaults: UserDefaults = .standard) -> String {
        nonEmpty(defaults.string(forKey: masterProfileKey)) ?? defaultProfile
    }

    static func masterRegion(_ defaults: UserDefaults = .standard) -> String {
        nonEmpty(defaults.string(forKey: masterRegionKey)) ?? defaultRegion
    }

    static func choice(for slot: AIAccountSlot, _ defaults: UserDefaults = .standard) -> AIAccountChoice {
        defaults.string(forKey: choiceKey(slot)).flatMap(AIAccountChoice.init(storedValue:)) ?? .master
    }

    static func setChoice(_ choice: AIAccountChoice, for slot: AIAccountSlot, _ defaults: UserDefaults = .standard) {
        if choice == .master {
            defaults.removeObject(forKey: choiceKey(slot))
        } else {
            defaults.set(choice.storedValue, forKey: choiceKey(slot))
        }
    }

    /// Explicit region for a slot, or nil for automatic.
    static func regionOverride(for slot: AIAccountSlot, _ defaults: UserDefaults = .standard) -> String? {
        nonEmpty(defaults.string(forKey: regionKey(slot)))
    }

    static func setRegionOverride(_ region: String?, for slot: AIAccountSlot, _ defaults: UserDefaults = .standard) {
        if let region = nonEmpty(region) {
            defaults.set(region, forKey: regionKey(slot))
        } else {
            defaults.removeObject(forKey: regionKey(slot))
        }
    }

    /// Follow a slot's choice to a profile and region. `sameAs` chains are
    /// walked with a visited set; a cycle or a dangling link falls back to
    /// the master, which always resolves.
    ///
    /// `profileRegion` looks up a profile's own region from `~/.aws/config`
    /// — injected so the resolution is testable without the file.
    static func resolved(
        for slot: AIAccountSlot,
        _ defaults: UserDefaults = .standard,
        profileRegion: (String) -> String? = { AWSCredentialLoader.loadRegion(profile: $0) }
    ) -> ResolvedAIAccount {
        var current = slot
        var visited: Set<AIAccountSlot> = []
        while visited.insert(current).inserted {
            switch choice(for: current, defaults) {
            case .master:
                return master(defaults)
            case .sameAs(let next):
                current = next
            case .profile(let name):
                let region = regionOverride(for: current, defaults)
                    ?? profileRegion(name)
                    ?? masterRegion(defaults)
                return ResolvedAIAccount(profile: name, region: region, isMaster: false)
            }
        }
        return master(defaults)
    }

    static func master(_ defaults: UserDefaults = .standard) -> ResolvedAIAccount {
        ResolvedAIAccount(profile: masterProfile(defaults), region: masterRegion(defaults), isMaster: true)
    }

    // MARK: - Legacy keys

    /// Builds before 0.50 stored the embedding override as two bare keys
    /// (`embeddingAWSProfile` / `embeddingAWSRegion`, blank meaning master).
    /// Rewrite them once into the slot form so the new pickers show what the
    /// user had chosen, then drop them so nothing reads both.
    static let legacyEmbeddingProfileKey = "embeddingAWSProfile"
    static let legacyEmbeddingRegionKey = "embeddingAWSRegion"

    static func migrateLegacyKeys(_ defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: choiceKey(.embeddings)) == nil else { return }
        if let profile = nonEmpty(defaults.string(forKey: legacyEmbeddingProfileKey)) {
            setChoice(.profile(profile), for: .embeddings, defaults)
            setRegionOverride(defaults.string(forKey: legacyEmbeddingRegionKey), for: .embeddings, defaults)
        }
        defaults.removeObject(forKey: legacyEmbeddingProfileKey)
        defaults.removeObject(forKey: legacyEmbeddingRegionKey)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

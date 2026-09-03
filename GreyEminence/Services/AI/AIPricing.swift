import Foundation

/// $/MTok prices for a Claude model family: Haiku 4.5, Sonnet 5, Opus 5 list
/// prices as of September 2026. Used
/// only for the estimated-cost labels in the UI — the ledger itself stores
/// tokens, so stale prices never corrupt stored data.
struct AIPricing: Sendable, Equatable {
    let inputPerMTok: Double
    let outputPerMTok: Double

    /// Cache reads bill at 10% of input; cache writes at 125%.
    var cacheReadPerMTok: Double { inputPerMTok * 0.1 }
    var cacheWritePerMTok: Double { inputPerMTok * 1.25 }

    static let haiku = AIPricing(inputPerMTok: 1, outputPerMTok: 5)
    static let sonnet = AIPricing(inputPerMTok: 2, outputPerMTok: 10)
    static let opus = AIPricing(inputPerMTok: 5, outputPerMTok: 25)

    /// Map a stored model identifier to a price family. Identifiers usually
    /// contain the family name ("anthropic:claude-haiku-…",
    /// "bedrock:us-east-1:…sonnet…"), but Bedrock application inference
    /// profile ARNs can hide it — those fall back to matching the ARN
    /// against the trajector-settings slots. nil means "unknown model";
    /// the UI shows tokens without a cost estimate.
    static func family(forModelIdentifier identifier: String, settings: TrajectorSettings?) -> AIPricing? {
        let lower = identifier.lowercased()
        if lower.contains("haiku") { return .haiku }
        if lower.contains("sonnet") { return .sonnet }
        if lower.contains("opus") { return .opus }

        if let settings {
            if let arn = settings.haikuModel, !arn.isEmpty, identifier.contains(arn) { return .haiku }
            if let arn = settings.sonnetModel, !arn.isEmpty, identifier.contains(arn) { return .sonnet }
            if let arn = settings.opusModel, !arn.isEmpty, identifier.contains(arn) { return .opus }
        }
        return nil
    }

    func cost(of usage: AIUsage) -> Double {
        let input = Double(usage.inputTokens) * inputPerMTok
        let output = Double(usage.outputTokens) * outputPerMTok
        let cacheRead = Double(usage.cacheReadTokens) * cacheReadPerMTok
        let cacheWrite = Double(usage.cacheWriteTokens) * cacheWritePerMTok
        return (input + output + cacheRead + cacheWrite) / 1_000_000
    }
}

/// Pure rollups over usage-ledger rows, decoupled from SwiftData so they
/// are unit-testable. Views snapshot `AIUsageEvent` rows into `Line`s.
enum AIUsageAggregator {
    struct Line: Sendable {
        let purpose: AIUsagePurpose
        let modelIdentifier: String
        let usage: AIUsage

        init(purpose: AIUsagePurpose, modelIdentifier: String, usage: AIUsage) {
            self.purpose = purpose
            self.modelIdentifier = modelIdentifier
            self.usage = usage
        }
    }

    struct Totals: Sendable, Equatable {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
        var estimatedCost: Double = 0
        /// False when any line's model couldn't be priced — the UI labels
        /// the estimate "tokens only" / partial.
        var pricedEverything = true

        /// All prompt-side tokens, the number users think of as "in".
        var totalInputSideTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens }
    }

    static func totals(_ lines: [Line], settings: TrajectorSettings?) -> Totals {
        var totals = Totals()
        for line in lines {
            totals.inputTokens += line.usage.inputTokens
            totals.outputTokens += line.usage.outputTokens
            totals.cacheReadTokens += line.usage.cacheReadTokens
            totals.cacheWriteTokens += line.usage.cacheWriteTokens
            if let pricing = AIPricing.family(forModelIdentifier: line.modelIdentifier, settings: settings) {
                totals.estimatedCost += pricing.cost(of: line.usage)
            } else {
                totals.pricedEverything = false
            }
        }
        return totals
    }

    /// Per-purpose rollup, ordered by estimated cost (unpriced groups last,
    /// by token volume).
    static func byPurpose(_ lines: [Line], settings: TrajectorSettings?) -> [(purpose: AIUsagePurpose, totals: Totals)] {
        Dictionary(grouping: lines, by: \.purpose)
            .map { (purpose: $0.key, totals: totals($0.value, settings: settings)) }
            .sorted {
                if $0.totals.estimatedCost != $1.totals.estimatedCost {
                    return $0.totals.estimatedCost > $1.totals.estimatedCost
                }
                return $0.totals.totalInputSideTokens > $1.totals.totalInputSideTokens
            }
    }

    /// One rollup bucket: group totals plus its per-purpose detail rows.
    struct GroupRollup: Sendable {
        let group: AIUsageGroup
        let totals: Totals
        let purposes: [(purpose: AIUsagePurpose, totals: Totals)]
    }

    /// Group-level rollup in fixed declaration order (transcript → final →
    /// screen shares → everything else); only non-empty groups are returned.
    static func byGroup(_ lines: [Line], settings: TrajectorSettings?) -> [GroupRollup] {
        let grouped = Dictionary(grouping: lines, by: \.purpose.group)
        return AIUsageGroup.allCases.compactMap { group in
            guard let groupLines = grouped[group], !groupLines.isEmpty else { return nil }
            return GroupRollup(
                group: group,
                totals: totals(groupLines, settings: settings),
                purposes: byPurpose(groupLines, settings: settings)
            )
        }
    }

    /// Compact token count for captions: 950 → "950", 12_340 → "12k",
    /// 1_234_000 → "1.2M".
    static func compactTokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: "\(count)"
        case ..<1_000_000: "\(count / 1_000)k"
        default: String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}

extension AIUsageAggregator.Line {
    @MainActor
    init(event: AIUsageEvent) {
        self.init(
            purpose: event.purpose,
            modelIdentifier: event.modelIdentifier,
            usage: AIUsage(
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                cacheReadTokens: event.cacheReadTokens,
                cacheWriteTokens: event.cacheWriteTokens
            )
        )
    }
}

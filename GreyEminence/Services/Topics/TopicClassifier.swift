import Foundation
import SwiftData

/// Sorts every meeting topic into a kind and spots aliases, filling the
/// `TopicCatalog`. Works per distinct topic, not per meeting: the first run
/// covers the whole library, later runs only topics never seen before.
///
/// Runs when the Topic Map or Refinements opens. Contact names become
/// People without asking the model; the rest go to Haiku in batches, each
/// topic with one meeting it came up in for context.
@Observable
@MainActor
final class TopicClassifier {
    static let shared = TopicClassifier()

    /// Bump on any change to the default prompt: the next run re-classifies
    /// every topic you haven't set yourself.
    nonisolated static let promptVersion = 1
    nonisolated static let batchSize = 150
    /// Neighbouring topics shown with each one.
    nonisolated static let contextTopics = 6

    private(set) var isRunning = false
    private(set) var checked = 0
    private(set) var total = 0
    private(set) var lastError: String?

    private init() {}

    func runIfNeeded(in context: ModelContext) {
        guard !isRunning else { return }
        let store = TopicCatalogStore.shared
        let contacts = ((try? context.fetch(FetchDescriptor<Contact>())) ?? []).map(\.name)
        let samples = Self.samples(from: (try? context.fetch(FetchDescriptor<MeetingInsight>())) ?? [])

        // A topic that is a contact's full name needs no model.
        let fullNames = Dictionary(
            contacts.map { (TopicCatalog.normalize($0), $0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            uniquingKeysWith: { first, _ in first }
        )
        let version = Self.promptVersion
        store.update { catalog in
            for sample in samples where fullNames[sample.key] != nil && catalog.entry(for: sample.label) == nil {
                catalog.apply(kind: .person, canonical: nil, to: sample.label)
            }
            catalog.dropImplausibleAliases(contactNames: contacts)
        }
        let pending = samples.filter { store.catalog.needsClassifying($0.label, version: version) }
        guard !pending.isEmpty else { return }

        isRunning = true
        checked = 0
        total = pending.count
        lastError = nil
        let people = Self.peopleList(contacts)

        Task {
            defer { isRunning = false }
            do {
                guard let client = try await AIClientFactory.makeLightClient() else {
                    lastError = "AI is not configured."
                    return
                }
                LogManager.send("Topic categories: classifying \(pending.count) topic(s)", category: .ai)
                for start in stride(from: 0, to: pending.count, by: Self.batchSize) {
                    let batch = Array(pending[start..<min(start + Self.batchSize, pending.count)])
                    let results = try await classify(batch, people: people, client: client)
                    store.update { catalog in
                        for (index, result) in results {
                            catalog.apply(kind: result.kind, canonical: result.canonical, to: batch[index].label, version: version)
                        }
                        catalog.dropImplausibleAliases(contactNames: contacts)
                    }
                    checked += batch.count
                }
                LogManager.send("Topic categories: done", category: .ai)
            } catch {
                lastError = error.localizedDescription
                LogManager.send("Topic categories failed: \(error.localizedDescription)", category: .ai, level: .warning)
            }
        }
    }

    private func classify(_ batch: [Sample], people: String, client: any AIClient) async throws -> [Int: Classification] {
        let prompt = AIPromptTemplates.topicClassifyPrompt(people: people, topics: Self.catalogue(batch))
        let system = AIPromptTemplates.topicClassifySystemPrompt
        let response = try await AIUsageContext.attribute(.topicClassification) {
            try await AIRetry.run(label: "topicClassification") { [client, system, prompt] in
                try await withTimeout(seconds: 120) {
                    try await client.sendMessage(system: system, userContent: prompt, maxTokens: 8192)
                }
            }
        }
        return Self.parse(response: response, count: batch.count)
    }

    // MARK: - Pure helpers (unit-tested)

    /// One distinct topic, with where it came up.
    struct Sample: Sendable, Equatable {
        let key: String
        /// The most common spelling.
        let label: String
        let meetingCount: Int
        /// The most recent meeting it came up in, and the topics beside it.
        let meetingTitle: String
        let neighbours: [String]
    }

    struct Classification: Sendable, Equatable {
        let kind: TopicKind
        let canonical: String?
    }

    /// Distinct topics across each meeting's latest insight — what the
    /// Topic Map shows — most-mentioned first.
    static func samples(from insights: [MeetingInsight]) -> [Sample] {
        var latest: [UUID: MeetingInsight] = [:]
        for insight in insights {
            guard let meeting = insight.meeting, !insight.topics.isEmpty else { continue }
            if let existing = latest[meeting.id], existing.createdAt >= insight.createdAt { continue }
            latest[meeting.id] = insight
        }

        struct Tally {
            var spellings: [String: Int] = [:]
            var meetings = 0
            var newest = Date.distantPast
            var title = ""
            var neighbours: [String] = []
        }
        var tallies: [String: Tally] = [:]
        for insight in latest.values {
            guard let meeting = insight.meeting else { continue }
            var seen = Set<String>()
            let topics = insight.topics
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert(TopicCatalog.normalize($0)).inserted }
            for topic in topics {
                let key = TopicCatalog.normalize(topic)
                var tally = tallies[key, default: Tally()]
                tally.spellings[topic, default: 0] += 1
                tally.meetings += 1
                if meeting.date > tally.newest {
                    tally.newest = meeting.date
                    tally.title = meeting.title
                    tally.neighbours = Array(topics.filter { TopicCatalog.normalize($0) != key }.prefix(contextTopics))
                }
                tallies[key] = tally
            }
        }
        return tallies.map { key, tally in
            Sample(
                key: key,
                label: tally.spellings.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? key,
                meetingCount: tally.meetings,
                meetingTitle: tally.title,
                neighbours: tally.neighbours
            )
        }
        .sorted { $0.meetingCount != $1.meetingCount ? $0.meetingCount > $1.meetingCount : $0.key < $1.key }
    }

    /// "T1: carlos — in "OLP Sync" with: OLP, Milo, Jira"
    nonisolated static func catalogue(_ batch: [Sample]) -> String {
        batch.enumerated().map { index, sample in
            var line = "T\(index + 1): \(sample.label) — in \"\(sample.meetingTitle)\""
            if !sample.neighbours.isEmpty { line += " with: " + sample.neighbours.joined(separator: ", ") }
            return line
        }.joined(separator: "\n")
    }

    nonisolated static func peopleList(_ names: [String]) -> String {
        let cleaned = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return cleaned.isEmpty ? "None recorded." : cleaned.sorted().joined(separator: "; ")
    }

    /// Batch position → classification. Entries with an unknown id or no
    /// readable kind are dropped; those topics are retried next run.
    nonisolated static func parse(response: String, count: Int) -> [Int: Classification] {
        guard let object = try? AIResponseDecoder.objectFrom(response),
              let items = object["topics"] as? [[String: Any]] else { return [:] }
        var result: [Int: Classification] = [:]
        for item in items {
            guard let id = item["id"] as? String,
                  id.uppercased().hasPrefix("T"),
                  let number = Int(id.dropFirst()),
                  (1...count).contains(number),
                  let rawKind = item["kind"] as? String,
                  let kind = TopicKind(rawValue: rawKind.lowercased().trimmingCharacters(in: .whitespaces)) else { continue }
            let canonical = (item["canonical"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // A topic's ID in place of a name ("T11") would merge unrelated
            // topics across batches, where the same ID means another topic.
            result[number - 1] = Classification(kind: kind, canonical: canonical.flatMap {
                $0.isEmpty || $0.lowercased() == "null" || TopicAliasCheck.isTopicID($0) ? nil : $0
            })
        }
        return result
    }
}

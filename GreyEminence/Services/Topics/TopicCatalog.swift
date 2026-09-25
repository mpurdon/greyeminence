import Foundation
import Observation

/// What a meeting topic names. One per distinct topic, library-wide:
/// "Walter" is a person in every meeting that mentions him.
enum TopicKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case person
    case organization
    case project
    case service
    case technology
    case concept
    case place
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .person: "People"
        case .organization: "Organizations"
        case .project: "Projects"
        case .service: "Services"
        case .technology: "Technology"
        case .concept: "Concepts"
        case .place: "Places"
        case .other: "Other"
        }
    }

    /// Singular, for a menu of one topic's category.
    var singular: String {
        switch self {
        case .person: "Person"
        case .organization: "Organization"
        case .project: "Project"
        case .service: "Service"
        case .technology: "Technology"
        case .concept: "Concept"
        case .place: "Place"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .person: "person.fill"
        case .organization: "building.2.fill"
        case .project: "flag.fill"
        case .service: "server.rack"
        case .technology: "cpu.fill"
        case .concept: "lightbulb.fill"
        case .place: "mappin.circle.fill"
        case .other: "circle.dashed"
        }
    }

    /// A kind this version doesn't know reads as Other rather than failing
    /// the whole catalog.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TopicKind(rawValue: raw.lowercased()) ?? .other
    }

    /// Kinds stored in `@AppStorage` as "person,place".
    static func set(from raw: String) -> Set<TopicKind> {
        Set(raw.split(separator: ",").compactMap { TopicKind(rawValue: String($0)) })
    }

    static func raw(_ kinds: Set<TopicKind>) -> String {
        allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// Every topic's category, and which topics are other names for the same
/// thing ("Carlos" for "Carlos Ayala Gonzalez", "dynamo" for "DynamoDB").
/// Keyed by normalized topic, like the Topic Map.
struct TopicCatalog: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var kind: TopicKind
        /// The fuller name this topic is another form of. Nil when the
        /// topic is its own name.
        var canonical: String?
        /// Set by you — never overwritten by a later classification.
        var kindIsUserSet = false
        var aliasIsUserSet = false
        /// The classifier prompt version this came from; nil for a contact's
        /// name, which needs no model. A newer prompt re-classifies it.
        var version: Int?
    }

    var entries: [String: Entry] = [:]

    static func normalize(_ topic: String) -> String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func entry(for topic: String) -> Entry? {
        entries[Self.normalize(topic)]
    }

    /// The key every form of a topic counts under: its canonical name's,
    /// followed a few hops in case a canonical is itself an alias.
    func key(for topic: String) -> String {
        var key = Self.normalize(topic)
        var seen: Set<String> = [key]
        while let canonical = entries[key]?.canonical {
            let next = Self.normalize(canonical)
            guard !next.isEmpty, seen.insert(next).inserted else { break }
            key = next
        }
        return key
    }

    /// The name to show for an alias — the canonical's own spelling. Nil
    /// for a topic that is its own name.
    func displayName(for topic: String) -> String? {
        let own = Self.normalize(topic)
        let key = key(for: topic)
        guard key != own else { return nil }
        // The last canonical in the chain, as written.
        var current = own
        var name: String?
        var seen: Set<String> = [own]
        while let canonical = entries[current]?.canonical {
            let next = Self.normalize(canonical)
            guard !next.isEmpty, seen.insert(next).inserted else { break }
            name = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            current = next
        }
        return name
    }

    /// The kind of what the topic names: an alias takes its canonical's
    /// (so re-categorising "Carlos Ayala Gonzalez" carries "Carlos" along),
    /// falling back to its own when the canonical was never classified.
    func kind(for topic: String) -> TopicKind? {
        entries[key(for: topic)]?.kind ?? entries[Self.normalize(topic)]?.kind
    }

    /// Whether `topic` still needs the classifier: never seen, or seen by
    /// an older prompt and not settled by you.
    func needsClassifying(_ topic: String, version: Int) -> Bool {
        guard let entry = entry(for: topic) else { return true }
        guard let classified = entry.version else { return false }
        return classified < version && !(entry.kindIsUserSet && entry.aliasIsUserSet)
    }

    /// Record a classification, keeping whatever you set yourself.
    /// `version` is the prompt's; nil for one made without the model.
    mutating func apply(kind: TopicKind, canonical: String?, to topic: String, version: Int? = nil) {
        let key = Self.normalize(topic)
        guard !key.isEmpty else { return }
        var entry = entries[key] ?? Entry(kind: kind)
        if !entry.kindIsUserSet { entry.kind = kind }
        if !entry.aliasIsUserSet {
            let trimmed = canonical?.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.canonical = trimmed.flatMap { Self.normalize($0) == key || $0.isEmpty ? nil : $0 }
        }
        entry.version = version
        entries[key] = entry
    }
}

extension TopicCatalog {
    /// Clear every alias the checks in `TopicAliasCheck` reject, except
    /// ones you set. Run over the whole catalog after each classification,
    /// so aliases stored before a check existed are cleaned too.
    mutating func dropImplausibleAliases(contactNames: [String]) {
        let check = TopicAliasCheck(contactNames: contactNames)
        for (key, entry) in entries {
            guard let canonical = entry.canonical, !entry.aliasIsUserSet else { continue }
            let kind = entries[Self.normalize(canonical)]?.kind ?? entry.kind
            if !check.isPlausible(alias: key, canonical: canonical, kind: kind) {
                entries[key]?.canonical = nil
            }
        }
    }
}

/// Whether "X is another name for Y" is believable, checked in code
/// because the model over-merges despite being told not to: "Steven Smith"
/// → "Steven Goodman", "matt" → one of two Matts, a topic ID ("T11") in
/// place of a name.
struct TopicAliasCheck: Sendable {
    /// Every contact's name, as words.
    let contacts: [[String]]

    init(contactNames: [String]) {
        contacts = contactNames.map(Self.words).filter { !$0.isEmpty }
    }

    func isPlausible(alias: String, canonical: String, kind: TopicKind) -> Bool {
        let a = Self.words(alias)
        let c = Self.words(canonical)
        guard !a.isEmpty, !c.isEmpty, !Self.isTopicID(canonical) else { return false }
        if kind == .person { return isPlausiblePerson(a, c) }
        let (squashedAlias, squashedCanonical) = (a.joined(), c.joined())
        return Self.spelledAlike(squashedAlias, squashedCanonical)
            || squashedAlias == Self.initials(of: c)
            || (squashedAlias.count >= 3 && squashedCanonical.hasPrefix(squashedAlias) && a.count == 1)
    }

    /// Each word of the alias matches a word of the name (or the alias run
    /// together does: "zhi hong" → "Zhihong"); and a one-word alias that
    /// could be several contacts ("Matt", "Steve") names none of them.
    private func isPlausiblePerson(_ alias: [String], _ name: [String]) -> Bool {
        // Run together, only when spelled nearly the same ("zi hong" /
        // "zhihong"); loosely, "Steven Smith" run together looks enough
        // like "steven" to pass.
        let matches = alias.allSatisfy { word in name.contains { Self.similar(word, $0) } }
            || (alias.count > 1 && name.contains { Self.ratio(alias.joined(), $0) >= 0.7 })
        guard matches else { return false }
        guard alias.count == 1, let word = alias.first, let firstName = name.first else { return true }
        // A first name competes only with other first names, a surname
        // with surnames: "walter" is not Evan Walker, "stephen" not Leah
        // Stephens.
        if Self.couldBe(word, firstName) {
            return contacts.filter { $0.first.map { Self.couldBe(word, $0) } ?? false }.count <= 1
        }
        return contacts.filter { $0.dropFirst().contains { Self.couldBe(word, $0) } }.count <= 1
    }

    /// Whether a one-word alias could stand for this name — stricter than
    /// `similar`, since it decides ambiguity: the same, a shortening ("greg"
    /// for "gregory"), or one letter off with the same initial ("eric" /
    /// "erick").
    static func couldBe(_ alias: String, _ word: String) -> Bool {
        alias == word
            || (alias.count >= 3 && word.hasPrefix(alias))
            || (alias.first == word.first && min(alias.count, word.count) >= 4 && ratio(alias, word) >= 0.8)
    }

    /// Lowercased words without accents or punctuation: "José's" → ["jose", "s"].
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func isTopicID(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^[Tt]\d+$"#, options: .regularExpression) != nil
    }

    private static let minorWords: Set<String> = ["and", "of", "the", "for", "a", "an", "to", "in", "on"]

    static func initials(of words: [String]) -> String {
        String(words.filter { !minorWords.contains($0) }.compactMap(\.first))
    }

    /// The same word, allowing for how names get transcribed: a prefix
    /// ("sid" / "sidharth"), or at most half the letters changed
    /// ("gussard" / "gossard").
    static func similar(_ a: String, _ b: String) -> Bool {
        if min(a.count, b.count) >= 3, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        return spelledAlike(a, b)
    }

    /// At most half the letters changed, for words of four letters or more.
    static func spelledAlike(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 4 else { return false }
        return ratio(a, b) >= 0.5
    }

    static func ratio(_ a: String, _ b: String) -> Double {
        1 - Double(editDistance(a, b)) / Double(max(a.count, b.count, 1))
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = a[i - 1] == b[j - 1] ? diagonal : min(diagonal, above, row[j - 1]) + 1
                diagonal = above
            }
        }
        return row[b.count]
    }
}

/// What a view needs to place a raw topic: the key it counts under, the
/// name to show, and its kind — or nothing, when its kind is hidden.
struct TopicResolver: Sendable {
    struct Resolved: Sendable, Equatable {
        let key: String
        /// The canonical name, when the topic is an alias of it.
        let displayName: String?
        let kind: TopicKind?
    }

    var catalog = TopicCatalog()
    var hiddenKinds: Set<TopicKind> = []
    /// Contact names, normalized — People for topics the classifier
    /// hasn't reached yet, so hiding People works from the first launch.
    var people: Set<String> = []

    func resolve(_ topic: String) -> Resolved? {
        let own = TopicCatalog.normalize(topic)
        guard !own.isEmpty else { return nil }
        let kind = catalog.kind(for: topic) ?? (people.contains(own) ? .person : nil)
        if let kind, hiddenKinds.contains(kind) { return nil }
        return Resolved(key: catalog.key(for: topic), displayName: catalog.displayName(for: topic), kind: kind)
    }

    /// Every way a topic can name a contact — full name, first name, last
    /// name — normalized like topics.
    static func personNames(_ names: [String]) -> Set<String> {
        var result = Set<String>()
        for name in names {
            let parts = TopicCatalog.normalize(name).split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = parts.first else { continue }
            result.insert(parts.joined(separator: " "))
            result.insert(first)
            if parts.count > 1, let last = parts.last { result.insert(last) }
        }
        return result
    }
}

/// The catalog on disk, shared by the Topic Map and Refinements.
@Observable
@MainActor
final class TopicCatalogStore {
    static let shared = TopicCatalogStore()

    private(set) var catalog: TopicCatalog
    /// Bumped on every change, for views that rebuild from the catalog.
    private(set) var revision = 0

    private init() {
        catalog = StorageManager.shared.loadTopicCatalog()
    }

    func resolver(hiding kinds: Set<TopicKind>, contactNames: [String]) -> TopicResolver {
        TopicResolver(catalog: catalog, hiddenKinds: kinds, people: TopicResolver.personNames(contactNames))
    }

    func update(_ change: (inout TopicCatalog) -> Void) {
        var next = catalog
        change(&next)
        guard next != catalog else { return }
        catalog = next
        StorageManager.shared.saveTopicCatalog(next)
        revision += 1
    }

    /// Your choice of category, kept through later classifications.
    func setKind(_ kind: TopicKind, for topic: String) {
        update { catalog in
            let key = TopicCatalog.normalize(topic)
            var entry = catalog.entries[key] ?? .init(kind: kind)
            entry.kind = kind
            entry.kindIsUserSet = true
            catalog.entries[key] = entry
        }
    }

    /// Stop counting `topic` as another name for its canonical.
    func separate(_ topic: String) {
        update { catalog in
            let key = TopicCatalog.normalize(topic)
            guard var entry = catalog.entries[key] else { return }
            entry.canonical = nil
            entry.aliasIsUserSet = true
            catalog.entries[key] = entry
        }
    }
}

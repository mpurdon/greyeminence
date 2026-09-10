import Foundation
import FluidAudio

/// What a vocabulary term *is*. The repair pass asks "does this word belong
/// in this slot?", and a kind is most of the answer: a person fits "X said",
/// a document type fits "the X shows", a system fits "migrated from X".
/// Without it the model matches on sound alone and rewrites ordinary words
/// into jargon that happens to rhyme.
enum TermKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case person
    case company
    case project
    case system
    case document
    case other

    var id: String { rawValue }

    /// For the Settings picker.
    var label: String {
        switch self {
        case .person: "Person"
        case .company: "Company"
        case .project: "Project"
        case .system: "System or tool"
        case .document: "Document or record"
        case .other: "Other"
        }
    }

    /// Group heading in the correction prompt. Plural, because it labels a list.
    var promptHeading: String {
        switch self {
        case .person: "People"
        case .company: "Companies"
        case .project: "Projects"
        case .system: "Systems and tools"
        case .document: "Documents and records"
        case .other: "Other terms"
        }
    }

    /// Fixed order so the rendered prompt is stable between runs.
    static let promptOrder: [TermKind] = [.person, .company, .project, .system, .document, .other]
}

struct VocabularyTerm: Codable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var boost: Float
    var kind: TermKind

    init(text: String, boost: Float = 10.0, kind: TermKind = .other) {
        self.id = UUID()
        self.text = text
        self.boost = boost
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, boost, kind
    }

    /// `kind` is decoded leniently: every term saved before kinds existed is
    /// on disk without one, and a hard failure there would drop the whole
    /// vocabulary rather than one field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        boost = try container.decode(Float.self, forKey: .boost)
        kind = (try? container.decodeIfPresent(TermKind.self, forKey: .kind)) as? TermKind ?? .other
    }
}

@Observable
@MainActor
final class VocabularyManager {
    var terms: [VocabularyTerm] = []

    private let storageURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GreyEminence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("vocabulary.json")
        load()
    }

    func addTerm(_ text: String, boost: Float = 10.0, kind: TermKind = .other) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !terms.contains(where: { $0.text.lowercased() == trimmed.lowercased() }) else { return }
        terms.append(VocabularyTerm(text: trimmed, boost: boost, kind: kind))
        save()
    }

    func removeTerm(at offsets: IndexSet) {
        terms.remove(atOffsets: offsets)
        save()
    }

    func removeTerm(id: UUID) {
        terms.removeAll { $0.id == id }
        save()
    }

    func updateTerm(id: UUID, text: String? = nil, boost: Float? = nil, kind: TermKind? = nil) {
        guard let idx = terms.firstIndex(where: { $0.id == id }) else { return }
        if let text { terms[idx].text = text }
        if let boost { terms[idx].boost = boost }
        if let kind { terms[idx].kind = kind }
        save()
    }

    /// Build a FluidAudio CustomVocabularyContext from stored terms.
    func buildContext() -> CustomVocabularyContext? {
        let valid = terms.filter { $0.text.count >= 2 }
        guard !valid.isEmpty else { return nil }
        let fluidTerms = valid.map {
            CustomVocabularyTerm(text: $0.text, weight: $0.boost)
        }
        return CustomVocabularyContext(terms: fluidTerms)
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(terms)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            LogManager.send("Failed to save vocabulary: \(error.localizedDescription)", category: .transcription, level: .warning)
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            terms = try JSONDecoder().decode([VocabularyTerm].self, from: data)
        } catch {
            LogManager.send("Failed to load vocabulary: \(error.localizedDescription)", category: .transcription, level: .warning)
        }
    }
}

import Foundation
import FluidAudio

struct VocabularyTerm: Codable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var boost: Float

    init(text: String, boost: Float = 10.0) {
        self.id = UUID()
        self.text = text
        self.boost = boost
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

    func addTerm(_ text: String, boost: Float = 10.0) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !terms.contains(where: { $0.text.lowercased() == trimmed.lowercased() }) else { return }
        terms.append(VocabularyTerm(text: trimmed, boost: boost))
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

    func updateTerm(id: UUID, text: String? = nil, boost: Float? = nil) {
        guard let idx = terms.firstIndex(where: { $0.id == id }) else { return }
        if let text { terms[idx].text = text }
        if let boost { terms[idx].boost = boost }
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

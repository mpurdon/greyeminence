import CryptoKit
import Foundation
import Observation

/// One diagram on the Diagrams list: a meeting and something detected in
/// it to draw.
struct DiagramTopic: Hashable, Identifiable {
    let meeting: Meeting
    let signal: DiagramSignal

    var id: String { "\(meeting.id.uuidString)|\(signal.id)" }

    /// The ID to refer to this diagram by, shaped like a meeting ID: the
    /// same for every redraw, and written into the meeting's diagrams file.
    var diagramID: String { Self.diagramID(meetingID: meeting.id, signalID: signal.id) }

    static func diagramID(meetingID: UUID, signalID: String) -> String {
        let digest = Array(SHA256.hash(data: Data("\(meetingID.uuidString)|\(signalID)".utf8)))
        let bytes = (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                     digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15])
        return UUID(uuid: bytes).uuidString
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Drawn diagrams on disk, and the drawings in flight — here rather than
/// in a view so a build keeps going when you look at something else.
@Observable
@MainActor
final class DiagramStore {
    static let shared = DiagramStore()

    private(set) var generating: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var revision = 0

    @ObservationIgnored private var shelves: [UUID: DiagramShelf] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Pending writes of edited shelves, one per meeting: typing in the
    /// inspector changes the diagram at once and saves when you pause.
    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    static let editSaveDelay: Duration = .milliseconds(600)

    private init() {}

    func diagram(for topic: DiagramTopic) -> StoredDiagram? {
        shelf(topic.meeting.id).diagrams[topic.signal.id]
    }

    func isGenerating(_ topic: DiagramTopic) -> Bool { generating.contains(topic.id) }
    func error(for topic: DiagramTopic) -> String? { errors[topic.id] }
    func dismissError(for topic: DiagramTopic) { errors[topic.id] = nil }

    func generate(_ topic: DiagramTopic) {
        let key = topic.id
        guard !generating.contains(key) else { return }
        let meetingID = topic.meeting.id
        let signalID = topic.signal.id
        let input = DiagramService.input(for: topic.meeting, signal: topic.signal)
        generating.insert(key)
        errors[key] = nil

        tasks[key] = Task {
            defer {
                generating.remove(key)
                tasks[key] = nil
            }
            do {
                guard let client = try await AIClientFactory.makeClient() else {
                    errors[key] = "AI is not configured. Add an account in Settings → AI."
                    return
                }
                let diagram = try await DiagramService(client: client).generate(input, meetingID: meetingID)
                save(diagram, meetingID: meetingID, signalID: signalID)
            } catch {
                guard !Task.isCancelled else { return }
                errors[key] = error.localizedDescription
                LogManager.send("Diagram failed: \(error.localizedDescription)", category: .ai, level: .error, meetingID: meetingID)
            }
        }
    }

    /// Meetings whose diagrams are being looked for again.
    private(set) var redetecting: Set<UUID> = []

    /// Looks for the meeting's diagrams again from its transcript, replaces
    /// what's listed with what's found, and draws each of them.
    func detectAgain(_ meeting: Meeting) {
        let meetingID = meeting.id
        guard !redetecting.contains(meetingID) else { return }
        let input = DiagramService.input(for: meeting, signal: DiagramSignal(kind: .flow, title: "", likelihood: 1))
        redetecting.insert(meetingID)
        errors[meetingID.uuidString] = nil

        Task {
            defer { redetecting.remove(meetingID) }
            do {
                guard let client = try await AIClientFactory.makeClient() else {
                    errors[meetingID.uuidString] = "AI is not configured. Add an account in Settings → AI."
                    return
                }
                let signals = try await DiagramService(client: client).detect(input, meetingID: meetingID)
                DiagramIndexStore.shared.record(signals, for: meetingID)
                for signal in signals where signal.isListed {
                    generate(DiagramTopic(meeting: meeting, signal: signal))
                }
            } catch {
                errors[meetingID.uuidString] = error.localizedDescription
                LogManager.send("Diagram detection failed: \(error.localizedDescription)", category: .ai, level: .error, meetingID: meetingID)
            }
        }
    }

    func detectionError(for meeting: Meeting) -> String? { errors[meeting.id.uuidString] }

    func cancel(_ topic: DiagramTopic) {
        tasks[topic.id]?.cancel()
    }

    /// Your change to a drawn diagram.
    func edit(_ topic: DiagramTopic, _ change: (inout StoredDiagram) -> Void) {
        guard var diagram = diagram(for: topic) else { return }
        let before = diagram
        change(&diagram)
        guard diagram != before else { return }
        diagram.editedAt = .now
        save(diagram, meetingID: topic.meeting.id, signalID: topic.signal.id, deferred: true)
    }

    private func shelf(_ meetingID: UUID) -> DiagramShelf {
        _ = revision
        if let cached = shelves[meetingID] { return cached }
        var loaded = StorageManager.shared.loadDiagramShelf(for: meetingID)
        // Diagrams drawn before they carried their ID get it now.
        let unstamped = loaded.diagrams.keys.filter { loaded.diagrams[$0]?.diagramID == nil }
        for signalID in unstamped {
            loaded.diagrams[signalID]?.diagramID = DiagramTopic.diagramID(meetingID: meetingID, signalID: signalID)
        }
        if !unstamped.isEmpty { StorageManager.shared.saveDiagramShelf(loaded, for: meetingID) }
        shelves[meetingID] = loaded
        return loaded
    }

    private func save(_ diagram: StoredDiagram, meetingID: UUID, signalID: String, deferred: Bool = false) {
        var shelf = shelf(meetingID)
        var diagram = diagram
        diagram.diagramID = DiagramTopic.diagramID(meetingID: meetingID, signalID: signalID)
        shelf.diagrams[signalID] = diagram
        shelves[meetingID] = shelf
        revision += 1
        pendingSaves[meetingID]?.cancel()
        guard deferred else {
            pendingSaves[meetingID] = nil
            StorageManager.shared.saveDiagramShelf(shelf, for: meetingID)
            return
        }
        pendingSaves[meetingID] = Task { [weak self] in
            try? await Task.sleep(for: Self.editSaveDelay)
            guard !Task.isCancelled, let self, let latest = self.shelves[meetingID] else { return }
            StorageManager.shared.saveDiagramShelf(latest, for: meetingID)
            self.pendingSaves[meetingID] = nil
        }
    }
}

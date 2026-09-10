import Foundation

/// Who spoke in a meeting, how much, in the order a filter menu should list
/// them. Pure and value-typed so the ordering is testable without SwiftData
/// or a view.
struct TranscriptSpeakerRoster: Equatable {

    struct Entry: Identifiable, Equatable {
        let speaker: Speaker
        let segmentCount: Int
        let seconds: TimeInterval

        var id: Speaker { speaker }
        var displayName: String { speaker.displayName }
        var isUnidentified: Bool { speaker.isUnidentified }

        /// "45s" / "3m" — the same shorthand the unidentified-voice chips use,
        /// because these sit next to each other on screen.
        var durationLabel: String {
            seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m"
        }
    }

    var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    /// One voice needs no filter — the control is hidden rather than shown
    /// with nothing to choose.
    var isFilterable: Bool { entries.count > 1 }

    func entry(for speaker: Speaker) -> Entry? {
        entries.first { $0.speaker == speaker }
    }

    /// Build from a meeting's segments.
    ///
    /// Ordered with the user first and everyone else by how long they spoke,
    /// longest first: the list is stable as names are assigned, which matters
    /// because tagging a voice is exactly when someone is reading it. Quiet
    /// voices land at the end, which is fine — a menu shows them all, and the
    /// unidentified-voice chips above the transcript surface them directly.
    static func build(
        speakers: [(speaker: Speaker, duration: TimeInterval)]
    ) -> TranscriptSpeakerRoster {
        var counts: [Speaker: (count: Int, seconds: TimeInterval)] = [:]
        var firstSeen: [Speaker: Int] = [:]
        for (offset, item) in speakers.enumerated() {
            // A negative or absurd duration (a mangled segment) must not let
            // one voice swamp the ordering.
            let duration = max(0, item.duration)
            let existing = counts[item.speaker] ?? (0, 0)
            counts[item.speaker] = (existing.count + 1, existing.seconds + duration)
            if firstSeen[item.speaker] == nil { firstSeen[item.speaker] = offset }
        }

        let entries = counts
            .map { Entry(speaker: $0.key, segmentCount: $0.value.count, seconds: $0.value.seconds) }
            .sorted { left, right in
                if left.speaker == .me || right.speaker == .me {
                    return left.speaker == .me
                }
                if left.seconds != right.seconds { return left.seconds > right.seconds }
                // Ties break on first appearance so the order never shuffles
                // between rebuilds of the same transcript.
                return (firstSeen[left.speaker] ?? 0) < (firstSeen[right.speaker] ?? 0)
            }
        return TranscriptSpeakerRoster(entries: entries)
    }
}

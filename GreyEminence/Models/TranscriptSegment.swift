import Foundation
import SwiftData

@Model
final class TranscriptSegment {
    var id: UUID
    var speakerData: Data
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var isFinal: Bool
    var createdAt: Date

    // Confidence indicator
    var confidence: Float = 1.0

    // Transcript corrections
    var isEdited: Bool = false
    var originalText: String?
    var originalSpeakerData: Data?

    // Interview section tagging
    var sectionTag: String?       // e.g. "System Design", "Behavioral"
    var sectionTagID: UUID?       // rubricSectionID (or intro/conclusion UUID)

    var meeting: Meeting?

    var speaker: Speaker {
        get {
            (try? JSONDecoder().decode(Speaker.self, from: speakerData)) ?? .me
        }
        set {
            speakerData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    init(
        speaker: Speaker,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        isFinal: Bool = false
    ) {
        self.id = UUID()
        self.speakerData = (try? JSONEncoder().encode(speaker)) ?? Data()
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.isFinal = isFinal
        self.createdAt = .now
    }

    var formattedTimestamp: String {
        let minutes = Int(startTime) / 60
        let seconds = Int(startTime) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

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

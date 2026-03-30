import Foundation
import SwiftData

enum BookmarkType: String, Codable, Sendable {
    case bookmark
    case redFlag
}

@Model
final class InterviewBookmark {
    var id: UUID
    var typeRawValue: String
    var timestamp: TimeInterval
    var note: String?
    var segmentID: UUID?
    var createdAt: Date

    var interview: Interview?

    var type: BookmarkType {
        get { BookmarkType(rawValue: typeRawValue) ?? .bookmark }
        set { typeRawValue = newValue.rawValue }
    }

    init(type: BookmarkType, timestamp: TimeInterval, note: String? = nil, segmentID: UUID? = nil) {
        self.id = UUID()
        self.typeRawValue = type.rawValue
        self.timestamp = timestamp
        self.note = note
        self.segmentID = segmentID
        self.createdAt = .now
    }
}

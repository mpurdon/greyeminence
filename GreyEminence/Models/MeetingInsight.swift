import Foundation
import SwiftData

@Model
final class MeetingInsight {
    var id: UUID
    var summary: String
    var followUpQuestions: [String]
    var topics: [String]
    var createdAt: Date

    var meeting: Meeting?

    init(
        summary: String,
        followUpQuestions: [String] = [],
        topics: [String] = []
    ) {
        self.id = UUID()
        self.summary = summary
        self.followUpQuestions = followUpQuestions
        self.topics = topics
        self.createdAt = .now
    }
}

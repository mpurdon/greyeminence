import Foundation
import SwiftData
import UniformTypeIdentifiers

/// A saved transcript file that can be replayed against different rubrics.
struct TranscriptFile: Codable {
    let title: String
    let date: Date
    let duration: TimeInterval
    let segments: [SegmentSnapshot]

    static let fileExtension = "getranscript"

    static var utType: UTType {
        UTType(exportedAs: "com.greyeminence.transcript")
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }

    static func read(from url: URL) throws -> TranscriptFile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptFile.self, from: data)
    }

    /// Create from a completed meeting's segments.
    static func from(meeting: Meeting) -> TranscriptFile {
        let snapshots = meeting.segments
            .sorted { $0.startTime < $1.startTime }
            .map { SegmentSnapshot(speaker: $0.speaker, text: $0.text, formattedTimestamp: $0.formattedTimestamp, isFinal: $0.isFinal) }
        return TranscriptFile(
            title: meeting.title,
            date: meeting.date,
            duration: meeting.duration,
            segments: snapshots
        )
    }
}

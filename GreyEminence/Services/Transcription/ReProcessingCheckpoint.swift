import Foundation

/// Durable mid-job state for the high-accuracy re-processing pass. Written
/// to a sidecar JSON file in the meeting's recording directory after every
/// completed chunk so a yielded / crashed / restarted job can pick up where
/// it left off instead of restarting from chunk 0.
struct ReProcessingCheckpoint: Codable, Sendable {
    static let currentVersion = 1

    /// Schema version. If we ever change the on-disk layout incompatibly,
    /// bump this and discard older files on load.
    var version: Int = ReProcessingCheckpoint.currentVersion

    /// Mic chunk filenames already transcribed, in the order they were
    /// processed. Filename — not URL — so renames of the recordings
    /// directory don't invalidate progress.
    var completedMicChunkNames: [String]

    /// System chunk filenames already transcribed.
    var completedSystemChunkNames: [String]

    /// Cumulative duration (seconds) of mic chunks already processed.
    /// Carried over so resumed chunks land at the right timeline offset.
    var accumulatedMicOffset: TimeInterval

    /// Cumulative duration (seconds) of system chunks already processed.
    var accumulatedSystemOffset: TimeInterval

    /// Segments produced so far, in emission order. Concatenated with
    /// newly-transcribed segments on resume.
    var segments: [PersistedSegment]

    struct PersistedSegment: Codable, Sendable {
        var source: PersistedSource
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        /// Optional so checkpoints written before confidence existed still
        /// decode; they resume as fully confident, which is what they were.
        var confidence: Float?

        init(_ segment: HighQualityTranscriber.Segment) {
            self.source = segment.source == .mic ? .mic : .system
            self.text = segment.text
            self.startTime = segment.startTime
            self.endTime = segment.endTime
            self.confidence = segment.confidence
        }

        func toSegment() -> HighQualityTranscriber.Segment {
            HighQualityTranscriber.Segment(
                source: source == .mic ? .mic : .system,
                text: text,
                startTime: startTime,
                endTime: endTime,
                confidence: confidence ?? 1
            )
        }
    }

    enum PersistedSource: String, Codable, Sendable {
        case mic
        case system
    }
}

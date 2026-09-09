import Foundation

/// Finds the slices of on-disk audio that cover a moment in a meeting.
///
/// Audio is written as a run of chunks (`mic.m4a`, `mic.part001.m4a`, …)
/// whose lengths only form a timeline when laid end to end, so this does the
/// same walk `ReProcessingQueue.chunks` and the transcriber do. Pure, with
/// the chunk length injected, so the boundary arithmetic is unit-testable
/// without writing audio files.
enum SegmentAudioLocator {

    struct Slice: Equatable, Sendable {
        let url: URL
        /// Seconds into this chunk where the slice starts.
        let start: TimeInterval
        /// Seconds into this chunk where the slice ends.
        let end: TimeInterval

        var duration: TimeInterval { end - start }
    }

    /// Breathing room either side of a segment. Transcriber boundaries are
    /// approximate, and a clipped first syllable is exactly the thing the
    /// user is trying to hear.
    static let padding: TimeInterval = 0.4
    /// Never play less than this, so a one-word segment is still audible.
    static let minimumDuration: TimeInterval = 0.5

    /// Slices of `chunks` covering `window`, in playback order. Chunks whose
    /// reported length is not positive still advance nothing and are skipped;
    /// callers pass a length function that substitutes a fallback for an
    /// unreadable chunk so the timeline holds, as re-processing does.
    static func slices(
        covering window: ClosedRange<TimeInterval>,
        chunks: [URL],
        length: (URL) -> TimeInterval
    ) -> [Slice] {
        var result: [Slice] = []
        var cursor: TimeInterval = 0
        for url in chunks {
            let chunkLength = length(url)
            guard chunkLength > 0, chunkLength.isFinite else { continue }
            let chunkStart = cursor
            let chunkEnd = cursor + chunkLength
            cursor = chunkEnd
            if chunkEnd <= window.lowerBound { continue }
            if chunkStart >= window.upperBound { break }
            let start = max(window.lowerBound, chunkStart) - chunkStart
            let end = min(window.upperBound, chunkEnd) - chunkStart
            if end - start > 0.01 {
                result.append(Slice(url: url, start: start, end: end))
            }
        }
        return result
    }

    /// The span of source audio to play for a segment. `offset` is the
    /// meeting's `audioStartOffset`: a split meeting's segments are on the
    /// child's clock, and the audio lives on the source recording's.
    static func window(
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval,
        offset: TimeInterval
    ) -> ClosedRange<TimeInterval> {
        let lower = max(0, offset + segmentStart - padding)
        let naturalEnd = offset + max(segmentEnd, segmentStart) + padding
        let upper = max(lower + minimumDuration, naturalEnd)
        return lower...upper
    }
}

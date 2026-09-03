import Foundation

/// Joins "who spoke when" onto "what was said".
///
/// The two come from different models and neither can do the other's job:
/// WhisperKit produces accurate text with timings but no notion of speakers,
/// FluidAudio produces speaker turns but no words. Re-processing used to
/// discard the diarization entirely and label every non-microphone segment
/// `"Speaker"`, which collapsed 359 of 429 meetings into a single anonymous
/// voice — 175 of them with three or more attendees.
///
/// Pure and time-based so the join can be tested without audio or models.
enum SpeakerAlignment {
    /// One diarized turn: a time range attributed to an opaque cluster id.
    struct Span: Equatable {
        let speakerID: String
        let start: TimeInterval
        let end: TimeInterval

        var duration: TimeInterval { max(0, end - start) }
    }

    /// The cluster that overlaps `start..<end` most.
    ///
    /// Most, not first: a segment routinely straddles a turn boundary, and
    /// whoever holds the majority of it is the speaker. Returns nil when
    /// nothing overlaps — silence, or audio the diarizer couldn't cluster —
    /// so the caller can fall back rather than attribute to a guess.
    static func dominantSpeakerID(from start: TimeInterval, to end: TimeInterval, in spans: [Span]) -> String? {
        guard end > start, !spans.isEmpty else { return nil }

        // Overlap and tie-break gathered in one pass. This runs once per
        // transcript segment — thousands of times per meeting — so a second
        // pass over every span, to order ties among the two or three speakers
        // actually in contention, was most of the work done for nothing.
        var totals: [String: TimeInterval] = [:]
        var firstOverlap: [String: TimeInterval] = [:]
        for span in spans {
            let overlap = min(end, span.end) - max(start, span.start)
            guard overlap > 0 else { continue }
            totals[span.speakerID, default: 0] += overlap
            firstOverlap[span.speakerID] = min(firstOverlap[span.speakerID] ?? .greatestFiniteMagnitude, span.start)
        }
        guard !totals.isEmpty else { return nil }

        // Ties go to whoever spoke first, so the result never depends on
        // dictionary ordering.
        return totals.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return (firstOverlap[lhs.key] ?? 0) > (firstOverlap[rhs.key] ?? 0)
        }?.key
    }

    /// Stable display labels for cluster ids, numbered by when each voice is
    /// first heard rather than by whatever order the diarizer emitted them —
    /// so "Speaker 1" is the first person to talk, which is what a reader
    /// expects.
    ///
    /// These numbers are only meaningful within one meeting. The same person
    /// is not "Speaker 2" in the next one, which is precisely why naming has
    /// to come from a voice profile rather than from the label.
    static func labels(forSpansOrderedByTime spans: [Span]) -> [String: String] {
        var labels: [String: String] = [:]
        var next = 1
        for span in spans.sorted(by: { $0.start < $1.start }) where labels[span.speakerID] == nil {
            labels[span.speakerID] = Speaker.numbered(next).displayName
            next += 1
        }
        return labels
    }

    /// Speech a cluster needs before it counts as a participant.
    ///
    /// Twenty seconds is a few sentences. It was three, which only caught
    /// coughs and crossfades and let through the failure that actually
    /// happens: a one-word "Yeah." mid-call is too little audio for a stable
    /// voice embedding, so it lands far from the speaker's centroid and seeds
    /// a new cluster, which then collects the rest of their backchannel. In a
    /// 25-minute 1:1 that cluster reached 13 seconds — a whole extra
    /// participant made of nothing but "Yeah", "Okay" and "Absolutely".
    /// Someone who genuinely says only that much is not a voice the reader
    /// needs numbered; in a single-voice meeting their words go to that voice,
    /// otherwise they keep the plain "Speaker" label.
    static let minimumParticipantSeconds: TimeInterval = 20

    /// Clusters too small to be a real participant.
    ///
    /// Diarizers emit slivers — a cough, a crossfade, half a word of overlap —
    /// and each one otherwise becomes a numbered "speaker" that never says
    /// anything, which makes a two-person call look like a panel.
    static func significantSpeakerIDs(
        in spans: [Span],
        minimumTotalSeconds: TimeInterval = minimumParticipantSeconds
    ) -> Set<String> {
        var totals: [String: TimeInterval] = [:]
        for span in spans {
            totals[span.speakerID, default: 0] += span.duration
        }
        return Set(totals.filter { $0.value >= minimumTotalSeconds }.keys)
    }
}

import Foundation

/// A second look at who said each turn, once the whole meeting has been heard.
///
/// The diarizer clusters online: each turn is matched against the voices it
/// has heard *so far*, and a new voice only gets its own cluster when it is far
/// from all of them. So the first thing a new person says lands on whoever
/// sounds most like them among the people already talking — in one team sync,
/// Paras's first nine seconds went to Carlos, whose voice his matched at 0.30,
/// because Paras's own cluster did not exist yet. Ten minutes later, with both
/// clusters established, that same turn matches Paras at 0.92.
///
/// This pass re-checks every turn against the clusters as they stand at the
/// end. It is deliberately reluctant: a turn moves only when it clearly
/// matches another voice and clearly does not match its own. On the meeting
/// above, correctly assigned turns matched their own cluster at 0.86 (median)
/// and never matched another above 0.47, which is where these numbers come
/// from. Pure — vectors in, vectors out — so it is testable without audio.
enum HindsightReassignment {
    /// A turn shorter than this carries too little voice to re-judge; a
    /// one-word interjection's embedding is noise either way.
    static let minimumTurnSeconds: TimeInterval = 2
    /// The turn has to actually match the voice it moves to, not merely
    /// match it better than a bad fit.
    static let minimumSimilarity: Float = 0.5
    /// And it has to match that voice clearly better than its own.
    static let minimumMargin: Float = 0.2

    struct Result {
        let turns: [DiarizedSegment]
        let moved: Int
        let movedSeconds: TimeInterval
    }

    /// Re-assign turns to the significant cluster they match best.
    ///
    /// Destinations are limited to `significant` clusters: moving a turn onto
    /// a sliver would resurrect a voice the participant floor has just
    /// removed. Sources are not limited — a sliver's turns are exactly the
    /// ones most likely to belong to somebody real.
    static func apply(to turns: [DiarizedSegment], among significant: Set<String>) -> Result {
        guard significant.count >= 1, !turns.isEmpty else {
            return Result(turns: turns, moved: 0, movedSeconds: 0)
        }

        var grouped: [String: [(embedding: [Float], seconds: Double)]] = [:]
        for turn in turns where !turn.embedding.isEmpty {
            grouped[turn.speakerID, default: []].append((turn.embedding, max(0, turn.endTime - turn.startTime)))
        }
        let signatures = grouped.compactMapValues { VoiceSignature.from(turns: $0) }
        let destinations = signatures.filter { significant.contains($0.key) }
        guard !destinations.isEmpty else {
            return Result(turns: turns, moved: 0, movedSeconds: 0)
        }
        // Any turn will do for the display label; it is per-run anyway.
        let labelFor = Dictionary(turns.map { ($0.speakerID, $0.speaker) }, uniquingKeysWith: { first, _ in first })

        var moved = 0
        var movedSeconds: TimeInterval = 0
        let result = turns.map { turn -> DiarizedSegment in
            let seconds = max(0, turn.endTime - turn.startTime)
            guard seconds >= minimumTurnSeconds,
                  let own = VoiceSignature.from(turns: [(turn.embedding, 1)]) else { return turn }

            // A sliver's signature is little more than this turn itself, so
            // matching it proves nothing; only a participant's voice counts
            // as the turn having somewhere it already belongs.
            let ownSimilarity = significant.contains(turn.speakerID)
                ? signatures[turn.speakerID].map { own.similarity(to: $0) } ?? 0
                : 0
            var best: (id: String, similarity: Float)?
            for (id, signature) in destinations where id != turn.speakerID {
                let similarity = own.similarity(to: signature)
                if best == nil || similarity > best!.similarity { best = (id, similarity) }
            }
            guard let best,
                  best.similarity >= minimumSimilarity,
                  best.similarity - ownSimilarity >= minimumMargin else { return turn }

            moved += 1
            movedSeconds += seconds
            return DiarizedSegment(
                speaker: labelFor[best.id] ?? turn.speaker,
                startTime: turn.startTime,
                endTime: turn.endTime,
                confidence: turn.confidence,
                speakerID: best.id,
                embedding: turn.embedding
            )
        }
        return Result(turns: result, moved: moved, movedSeconds: movedSeconds)
    }
}

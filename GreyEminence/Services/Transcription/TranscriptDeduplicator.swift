import Foundation

/// Removes duplicate transcript segments caused by the microphone picking up
/// system audio output (speaker bleed). When the same utterance appears as both
/// a system audio segment (more accurate) and a mic segment (echo), the mic
/// segment is removed.
struct TranscriptDeduplicator {

    /// Minimum fraction of time overlap between two segments to consider them
    /// temporally coincident. Based on the shorter segment's duration.
    static let timeOverlapThreshold: Double = 0.3

    /// Minimum text similarity (0–1) to consider two segments as duplicates.
    /// Uses bigram similarity which is robust to minor ASR differences.
    static let textSimilarityThreshold: Double = 0.45

    /// Maximum allowed time gap (seconds) between segment midpoints to even
    /// attempt similarity comparison. Avoids comparing distant segments.
    static let maxMidpointGap: Double = 10.0

    struct DeduplicationResult {
        let segments: [TranscriptSegment]
        let removedCount: Int
        let removedSegments: [TranscriptSegment]
    }

    /// Deduplicate segments by removing mic echo segments that match system
    /// audio segments. System audio segments are preferred as they are
    /// captured directly from the audio stream and are more accurate.
    static func deduplicate(_ segments: [TranscriptSegment]) -> DeduplicationResult {
        let sorted = segments.sorted { $0.startTime < $1.startTime }

        // Separate mic (.me) and system (.other) segments
        let micSegments = sorted.filter { $0.speaker.isMe }
        let systemSegments = sorted.filter { !$0.speaker.isMe }

        guard !micSegments.isEmpty, !systemSegments.isEmpty else {
            return DeduplicationResult(segments: sorted, removedCount: 0, removedSegments: [])
        }

        var micIDsToRemove = Set<UUID>()

        for mic in micSegments {
            // Skip manual notes
            if mic.text.hasPrefix("[Note]") { continue }

            let micMid = (mic.startTime + mic.endTime) / 2.0

            for sys in systemSegments {
                // Quick distance check before expensive similarity
                let sysMid = (sys.startTime + sys.endTime) / 2.0
                guard abs(micMid - sysMid) <= maxMidpointGap else { continue }

                // Check time overlap
                let overlap = timeOverlap(mic, sys)
                guard overlap >= timeOverlapThreshold else { continue }

                // Check text similarity
                let similarity = textSimilarity(mic.text, sys.text)
                if similarity >= textSimilarityThreshold {
                    micIDsToRemove.insert(mic.id)
                    break // This mic segment is a duplicate, no need to check more
                }
            }
        }

        let kept = sorted.filter { !micIDsToRemove.contains($0.id) }
        let removed = sorted.filter { micIDsToRemove.contains($0.id) }

        return DeduplicationResult(
            segments: kept,
            removedCount: removed.count,
            removedSegments: removed
        )
    }

    // MARK: - Time Overlap

    /// Returns the fraction of overlap relative to the shorter segment's duration.
    /// 0 = no overlap, 1 = complete overlap.
    static func timeOverlap(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Double {
        let overlapStart = max(a.startTime, b.startTime)
        let overlapEnd = min(a.endTime, b.endTime)
        let overlapDuration = max(0, overlapEnd - overlapStart)

        let aDuration = max(a.endTime - a.startTime, 0.1) // avoid div by zero
        let bDuration = max(b.endTime - b.startTime, 0.1)
        let shorter = min(aDuration, bDuration)

        return overlapDuration / shorter
    }

    // MARK: - Text Similarity (Bigram / Dice coefficient)

    /// Computes the Dice coefficient over character bigrams of the two strings.
    /// Case-insensitive. Returns 0–1 where 1 is identical.
    /// Robust to minor word-level ASR differences (insertions, substitutions).
    static func textSimilarity(_ a: String, _ b: String) -> Double {
        let aNorm = normalize(a)
        let bNorm = normalize(b)

        guard aNorm.count >= 2, bNorm.count >= 2 else {
            // For very short strings, fall back to exact match
            return aNorm == bNorm ? 1.0 : 0.0
        }

        let aBigrams = bigrams(aNorm)
        let bBigrams = bigrams(bNorm)

        guard !aBigrams.isEmpty, !bBigrams.isEmpty else { return 0 }

        // Count matching bigrams
        var bCounts: [String: Int] = [:]
        for b in bBigrams {
            bCounts[b, default: 0] += 1
        }

        var matches = 0
        for a in aBigrams {
            if let count = bCounts[a], count > 0 {
                matches += 1
                bCounts[a] = count - 1
            }
        }

        return Double(2 * matches) / Double(aBigrams.count + bBigrams.count)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^\w\s]"#, with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func bigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count >= 2 else { return [] }
        return (0..<chars.count - 1).map { String(chars[$0]) + String(chars[$0 + 1]) }
    }
}

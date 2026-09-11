import Foundation

/// Removes duplicate transcript segments caused by the microphone picking up
/// system audio output (speaker bleed). When the same utterance appears as both
/// a system audio segment (more accurate) and a mic segment (echo), the mic
/// segment is removed.
struct TranscriptDeduplicator {

    /// Minimum text similarity (0–1) to consider two segments as duplicates.
    /// Uses bigram similarity which is robust to minor ASR differences.
    static let textSimilarityThreshold: Double = 0.45

    /// Maximum allowed time gap (seconds) between segment midpoints.
    static let maxMidpointGap: Double = 15.0

    /// Maximum seconds the mic segment's start time can lag behind the system
    /// segment's start time. Echo always arrives after the source, so we allow
    /// up to this much delay. A small negative value allows for ASR timing jitter.
    static let maxEchoDelay: Double = 8.0

    /// How far before the system segment's start the mic can begin (ASR jitter).
    static let maxLeadTime: Double = 2.0

    // MARK: Fragments

    /// A mic line that is a *piece* of a system line. Dice is symmetric, so
    /// a clean echo of "in Anthropic" against a hundred-character line scores
    /// about 0.2 and survives. Containment asks the right question — how much
    /// of the fragment is in the line — and a better microphone (the Yeti,
    /// since v0.36) hears the speakers clearly enough that Whisper now
    /// produces exactly these tidy fragments.
    static let containmentThreshold: Double = 0.7
    /// Below these the fragment is too short to be evidence of anything:
    /// "okay" or "yeah" is in every line of every meeting.
    static let minFragmentWords = 2
    static let minFragmentBigrams = 10
    /// A fragment echoed from the tail of a long line starts long after the
    /// line did, so its window runs from just before the line starts to a
    /// little after it ends — not from the line's start alone.
    static let maxTrailingEcho: Double = 8.0

    // MARK: Loudness

    /// The far side heard through the speakers is much quieter on the mic
    /// than the user's own voice. Below this fraction of the user's baseline
    /// a mic line is treated as someone else's, and the text only has to
    /// resemble a system line rather than match it.
    static let quietRatio: Float = 0.4
    /// Text thresholds for a quiet line — the loudness has already done most
    /// of the work, so the words need only corroborate.
    static let quietSimilarityThreshold: Double = 0.25
    static let quietContainmentThreshold: Double = 0.5
    /// A baseline needs this many mic lines that are certainly the user's
    /// (nothing on the far side near them) before loudness is trusted.
    static let minBaselineSamples = 4

    struct DeduplicationResult {
        let segments: [TranscriptSegment]
        let removedCount: Int
        let removedSegments: [TranscriptSegment]
        /// Quiet mic lines that matched nothing but were spoken while the
        /// far side was talking: relabelled to the unidentified far-side
        /// speaker rather than left as the user's words.
        var reassignedCount: Int = 0
        var reassignedSegments: [TranscriptSegment] = []
        /// The user's own-voice RMS the quiet test was measured against, or
        /// nil when there was not enough to measure.
        var userLevelBaseline: Float? = nil
    }

    /// Scores for the best-matching system segment against a mic segment.
    /// Used for debug display — shows why a segment was or wasn't removed.
    struct MatchDebugInfo {
        let systemText: String
        let midpointGap: Double       // seconds between midpoints
        let echoDelay: Double         // mic.startTime - sys.startTime (positive = mic is later)
        let textSimilarity: Double    // 0–1, threshold: 0.45
        /// 0–1, how much of the mic text's bigrams appear in the system text.
        let containment: Double
        /// The fragment's start fell inside the system line's span (plus slack).
        let fragmentTimingOk: Bool
        /// Mic loudness as a fraction of the user's baseline; nil when
        /// unmeasured. Under `quietRatio` this line is somebody else.
        let levelRatio: Float?
        let wouldRemove: Bool
    }

    /// Returns debug scoring info for a single mic segment against all system segments.
    /// Returns the best candidate (highest text similarity among those passing midpoint check).
    /// `systemSegments` must be sorted by `startTime` ascending.
    static func debugMatch(mic: TranscriptSegment, sortedSystemSegments: [TranscriptSegment], userLevelBaseline: Float? = nil) -> MatchDebugInfo? {
        guard !mic.text.hasPrefix("[Note]") else { return nil }
        let ratio = levelRatio(of: mic, baseline: userLevelBaseline)
        let quiet = isQuiet(ratio)
        let micMid = (mic.startTime + mic.endTime) / 2.0
        let windowLow  = micMid - maxMidpointGap
        let windowHigh = micMid + maxMidpointGap

        let sysMids = sortedSystemSegments.map { ($0.startTime + $0.endTime) / 2.0 }
        let lo = lowerBound(sysMids, target: windowLow)

        var best: MatchDebugInfo?
        var idx = lo
        while idx < sortedSystemSegments.count && sysMids[idx] <= windowHigh {
            let sys = sortedSystemSegments[idx]
            let gap = abs(micMid - sysMids[idx])
            let delay = mic.startTime - sys.startTime
            let similarity = textSimilarity(mic.text, sys.text)
            let timingOk = delay >= -maxLeadTime && delay <= maxEchoDelay
            let containment = fragmentContainment(mic.text, in: sys.text)
            let fragmentTimingOk = fragmentTiming(micStart: mic.startTime, sys: sys)
            let wouldRemove = isDuplicate(
                similarity: similarity, timingOk: timingOk,
                containment: containment, fragmentTimingOk: fragmentTimingOk,
                quiet: quiet
            )

            let score = max(similarity, containment)
            if best == nil || score > max(best!.textSimilarity, best!.containment) {
                best = MatchDebugInfo(
                    systemText: sys.text,
                    midpointGap: gap,
                    echoDelay: delay,
                    textSimilarity: similarity,
                    containment: containment,
                    fragmentTimingOk: fragmentTimingOk,
                    levelRatio: ratio,
                    wouldRemove: wouldRemove
                )
            }
            idx += 1
        }
        return best
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

        // Pre-extract midpoints for binary search (both arrays are startTime-sorted)
        let sysMids = systemSegments.map { ($0.startTime + $0.endTime) / 2.0 }
        let baseline = userLevelBaseline(micSegments: micSegments, systemSegments: systemSegments, sysMids: sysMids)

        var micIDsToRemove = Set<UUID>()
        var reassigned: [TranscriptSegment] = []

        for mic in micSegments {
            if mic.text.hasPrefix("[Note]") { continue }

            let quiet = isQuiet(levelRatio(of: mic, baseline: baseline))
            let micMid = (mic.startTime + mic.endTime) / 2.0
            let windowLow  = micMid - maxMidpointGap
            let windowHigh = micMid + maxMidpointGap

            // Binary-search for the first system segment whose midpoint >= windowLow
            let lo = lowerBound(sysMids, target: windowLow)
            // Scan forward until midpoint exceeds windowHigh
            var idx = lo
            var farSideWasTalking = false
            var matched = false
            while idx < systemSegments.count && sysMids[idx] <= windowHigh {
                let sys = systemSegments[idx]
                let delay = mic.startTime - sys.startTime
                let timingOk = delay >= -maxLeadTime && delay <= maxEchoDelay
                let fragmentTimingOk = fragmentTiming(micStart: mic.startTime, sys: sys)
                if timingOk || fragmentTimingOk { farSideWasTalking = true }
                let similarity = timingOk ? textSimilarity(mic.text, sys.text) : 0
                let containment = fragmentTimingOk ? fragmentContainment(mic.text, in: sys.text) : 0
                if isDuplicate(
                    similarity: similarity, timingOk: timingOk,
                    containment: containment, fragmentTimingOk: fragmentTimingOk,
                    quiet: quiet
                ) {
                    micIDsToRemove.insert(mic.id)
                    matched = true
                    break
                }
                idx += 1
            }

            // Quiet, unmatched, and the far side was talking: this is the
            // speakers, transcribed differently from the system track (or
            // missed by it). It is not the user's line. Relabel rather than
            // delete — it may be the only record of those words.
            if !matched, quiet, farSideWasTalking, mic.speaker.isMe {
                if !mic.isEdited, mic.originalSpeakerData == nil {
                    mic.originalSpeakerData = mic.speakerData
                }
                mic.speaker = .unidentified
                reassigned.append(mic)
            }
        }

        let kept = sorted.filter { !micIDsToRemove.contains($0.id) }
        let removed = sorted.filter { micIDsToRemove.contains($0.id) }

        return DeduplicationResult(
            segments: kept,
            removedCount: removed.count,
            removedSegments: removed,
            reassignedCount: reassigned.count,
            reassignedSegments: reassigned,
            userLevelBaseline: baseline
        )
    }

    // MARK: - Loudness helpers

    /// The duplicate decision, shared by the pass and the debug row. A quiet
    /// line needs far less textual agreement than a loud one.
    static func isDuplicate(
        similarity: Double, timingOk: Bool,
        containment: Double, fragmentTimingOk: Bool,
        quiet: Bool
    ) -> Bool {
        let similarityBar = quiet ? quietSimilarityThreshold : textSimilarityThreshold
        let containmentBar = quiet ? quietContainmentThreshold : containmentThreshold
        return (timingOk && similarity >= similarityBar)
            || (fragmentTimingOk && containment >= containmentBar)
    }

    static func levelRatio(of mic: TranscriptSegment, baseline: Float?) -> Float? {
        guard let baseline, baseline > 0, let level = mic.micLevel else { return nil }
        return level / baseline
    }

    static func isQuiet(_ ratio: Float?) -> Bool {
        guard let ratio else { return false }
        return ratio < quietRatio
    }

    /// The loudness of the user's own voice: the median level of mic lines
    /// with nothing on the far side anywhere near them, which are the user
    /// beyond doubt. Falls back to the median of every levelled mic line
    /// when too few are that clean, and to nil — loudness ignored — when
    /// there is not enough to measure at all.
    static func userLevelBaseline(
        micSegments: [TranscriptSegment],
        systemSegments: [TranscriptSegment],
        sysMids: [Double]
    ) -> Float? {
        let levelled = micSegments.filter { ($0.micLevel ?? 0) > 0 }
        guard !levelled.isEmpty else { return nil }

        var solo: [Float] = []
        for mic in levelled {
            let micMid = (mic.startTime + mic.endTime) / 2.0
            let lo = lowerBound(sysMids, target: micMid - maxMidpointGap)
            var alone = true
            var idx = lo
            while idx < systemSegments.count && sysMids[idx] <= micMid + maxMidpointGap {
                if fragmentTiming(micStart: mic.startTime, sys: systemSegments[idx]) { alone = false; break }
                idx += 1
            }
            if alone, let level = mic.micLevel { solo.append(level) }
        }
        let pool = solo.count >= minBaselineSamples ? solo : levelled.compactMap(\.micLevel)
        guard pool.count >= minBaselineSamples else { return nil }
        return median(pool)
    }

    static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Whether a mic line could be an echo of any part of `sys`: it starts no
    /// earlier than ASR jitter allows before the line, and no later than the
    /// echo delay allows after the line has ended.
    static func fragmentTiming(micStart: TimeInterval, sys: TranscriptSegment) -> Bool {
        micStart >= sys.startTime - maxLeadTime && micStart <= sys.endTime + maxTrailingEcho
    }

    /// Share of `fragment`'s bigrams found in `text` (0–1). Zero when the
    /// fragment is too short to mean anything, so a stray "okay" is never a
    /// duplicate of the line it happens to appear in.
    static func fragmentContainment(_ fragment: String, in text: String) -> Double {
        let fragNorm = normalize(fragment)
        let textNorm = normalize(text)
        let words = fragNorm.split(separator: " ").count
        let fragBigrams = bigrams(fragNorm)
        guard words >= minFragmentWords, fragBigrams.count >= minFragmentBigrams else { return 0 }
        // Only a fragment: a line as long as its match is Dice's job.
        guard fragBigrams.count < bigrams(textNorm).count else { return 0 }

        var available: [String: Int] = [:]
        for bigram in bigrams(textNorm) { available[bigram, default: 0] += 1 }
        var matches = 0
        for bigram in fragBigrams where (available[bigram] ?? 0) > 0 {
            available[bigram]! -= 1
            matches += 1
        }
        return Double(matches) / Double(fragBigrams.count)
    }

    /// Returns the index of the first element in `array` that is >= `target`.
    private static func lowerBound(_ array: [Double], target: Double) -> Int {
        var lo = 0, hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if array[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
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

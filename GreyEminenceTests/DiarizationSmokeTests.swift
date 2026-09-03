import XCTest
@testable import Grey_Eminence

/// A diagnostic, not a unit test: runs the real diarizer over real recorded
/// audio and reports what it heard.
///
/// The alignment logic is covered by `SpeakerAlignmentTests`; what that can't
/// tell you is whether FluidAudio actually separates voices on a Teams call at
/// the window size the repair uses. Skips cleanly when the audio isn't there,
/// so CI and other machines are unaffected.
final class DiarizationSmokeTests: XCTestCase {

    /// Which meeting to diarize, read from a file inside the app container:
    ///   …/Application Support/GreyEminence/diarize-target.txt
    ///
    /// Not an environment variable (xcodebuild doesn't forward the shell's)
    /// and not a default (a sandboxed host reads preferences from its own
    /// container, not the domain `defaults write` targets). Missing means
    /// skip — this costs minutes and needs recordings only a dev machine has.
    private var meetingID: String {
        let url = StorageManager.shared.appSupportURL.appendingPathComponent("diarize-target.txt")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testDiarizeRealMeetingAudio() async throws {
        try XCTSkipIf(meetingID.isEmpty, "Write a meeting UUID to diarize-target.txt in the app container to run.")

        // Resolved through the storage manager, not a hard-coded container
        // path: the test host is sandboxed, so `NSHomeDirectory()` is already
        // inside the container and appending the container path again finds
        // nothing.
        guard let id = UUID(uuidString: meetingID) else {
            throw XCTSkip("\(meetingID) is not a meeting UUID.")
        }
        let chunks = AudioFileWriter.existingChunkURLs(base: StorageManager.shared.systemAudioURL(for: id))
        try XCTSkipIf(chunks.isEmpty, "No system audio for \(meetingID) at \(StorageManager.shared.systemAudioURL(for: id).path).")

        let service = SpeakerDiarizationService()
        try await service.prepare()

        let started = Date()
        let segments = try await service.diarizeTrack(chunkURLs: chunks)
        let elapsed = Date().timeIntervalSince(started)

        let spans = segments.map {
            SpeakerAlignment.Span(speakerID: $0.speakerID, start: $0.startTime, end: $0.endTime)
        }
        let significant = SpeakerAlignment.significantSpeakerIDs(in: spans)
        var talkTime: [String: TimeInterval] = [:]
        for span in spans { talkTime[span.speakerID, default: 0] += span.duration }
        let covered = spans.reduce(0) { $0 + $1.duration }
        let span = (spans.map(\.end).max() ?? 0) - (spans.map(\.start).min() ?? 0)

        print("""

        ── diarization: \(meetingID) ──
        chunks:        \(chunks.count)
        wall clock:    \(String(format: "%.1f", elapsed))s
        turns:         \(segments.count)
        raw clusters:  \(talkTime.count)
        significant:   \(significant.count)  (>= \(Int(SpeakerAlignment.minimumParticipantSeconds))s of speech)
        audio spanned: \(String(format: "%.0f", span))s, attributed \(String(format: "%.0f", covered))s
        talk time (total / turns / longest turn / median turn):
        \(talkTime.sorted { $0.value > $1.value }
            .map { id, total -> String in
                let turns = spans.filter { $0.speakerID == id }.map(\.duration).sorted()
                let longest = turns.last ?? 0
                let median = turns.isEmpty ? 0 : turns[turns.count / 2]
                let tag = significant.contains(id) ? "" : "   (sliver)"
                return "  \(id.prefix(12).padding(toLength: 12, withPad: " ", startingAt: 0))  \(String(format: "%6.1f", total))s  \(String(format: "%3d", turns.count)) turns  longest \(String(format: "%5.1f", longest))s  median \(String(format: "%4.1f", median))s\(tag)"
            }
            .joined(separator: "\n"))
        cluster similarity (duration-weighted signatures):
        \(similarityMatrix(segments, talkTime: talkTime))
        hindsight:     \(hindsightSummary(segments, significant: significant))

        """)

        dumpTurns(segments, talkTime: talkTime)

        XCTAssertFalse(segments.isEmpty, "diarizer produced no turns at all")
        // Embeddings are what cross-meeting voice matching will key on, so
        // confirm they're actually coming through before building on them.
        XCTAssertFalse(segments.first?.embedding.isEmpty ?? true, "no voice embedding on the turns")
    }

    private func hindsightSummary(_ segments: [DiarizedSegment], significant: Set<String>) -> String {
        let result = HindsightReassignment.apply(to: segments, among: significant)
        guard result.moved > 0 else { return "nothing to move" }
        var moves: [String: Int] = [:]
        for (before, after) in zip(segments, result.turns) where before.speakerID != after.speakerID {
            moves["\(before.speakerID)→\(after.speakerID)", default: 0] += 1
        }
        return "would move \(result.moved) turn(s), \(Int(result.movedSeconds))s: "
            + moves.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
    }

    /// Every turn with its similarity to each cluster's final signature,
    /// written beside `diarize-target.txt` as `diarize-dump.csv`. This is how
    /// you tell a cold-start misassignment (the turn is closer to another
    /// cluster in hindsight) from a segmentation miss (there is no turn).
    private func dumpTurns(_ segments: [DiarizedSegment], talkTime: [String: TimeInterval]) {
        let ids = talkTime.filter { $0.value >= 3 }.sorted { $0.value > $1.value }.map(\.key)
        var sigs: [String: VoiceSignature] = [:]
        for id in ids {
            let turns = segments.filter { $0.speakerID == id }.map { (embedding: $0.embedding, seconds: max(0, $0.endTime - $0.startTime)) }
            sigs[id] = VoiceSignature.from(turns: turns)
        }
        var lines = ["speaker,start,end,quality," + ids.map { "sim_\($0)" }.joined(separator: ",")]
        for turn in segments.sorted(by: { $0.startTime < $1.startTime }) {
            let own = VoiceSignature.from(turns: [(embedding: turn.embedding, seconds: 1)])
            let sims = ids.map { id -> String in
                guard let own, let sig = sigs[id] else { return "" }
                return String(format: "%.3f", own.similarity(to: sig))
            }
            lines.append("\(turn.speakerID),\(String(format: "%.2f", turn.startTime)),\(String(format: "%.2f", turn.endTime)),\(String(format: "%.3f", turn.confidence)),\(sims.joined(separator: ","))")
        }
        let url = StorageManager.shared.appSupportURL.appendingPathComponent("diarize-dump.csv")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        print("turn dump: \(url.path)")
    }

    /// Cosine similarity between every pair of clusters with a few seconds
    /// behind them — whether a split voice is recoverable by similarity.
    private func similarityMatrix(_ segments: [DiarizedSegment], talkTime: [String: TimeInterval]) -> String {
        let ids = talkTime.filter { $0.value >= 3 }.sorted { $0.value > $1.value }.map(\.key)
        var sigs: [String: VoiceSignature] = [:]
        for id in ids {
            let turns = segments.filter { $0.speakerID == id }.map { (embedding: $0.embedding, seconds: max(0, $0.endTime - $0.startTime)) }
            sigs[id] = VoiceSignature.from(turns: turns)
        }
        var lines: [String] = []
        for i in ids.indices {
            for j in ids.indices where j > i {
                guard let a = sigs[ids[i]], let b = sigs[ids[j]] else { continue }
                lines.append("  \(ids[i]) ~ \(ids[j]): \(String(format: "%.3f", a.similarity(to: b)))")
            }
        }
        return lines.isEmpty ? "  (one cluster)" : lines.joined(separator: "\n")
    }
}

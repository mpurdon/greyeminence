import Foundation
import SwiftData

/// Re-attributes transcripts whose speaker labels an older build got wrong.
///
/// Two shapes of wrong. Collapsed: written before diarization survived
/// re-processing, so every remote voice is labelled `"Speaker"`. Over-split:
/// written before one-word interjections stopped seeding their own cluster,
/// so a two-person call shows a "Speaker 2" made of nothing but "Yeah", or a
/// stray anonymous "Speaker" beside the one real remote voice.
///
/// Either way the text is fine — WhisperKit produced it — and re-running the
/// whole re-transcription would cost hours of inference to change a label.
/// This does the cheap half: diarize the audio that is still on disk and
/// relabel in place, leaving the words and timings untouched.
@MainActor
enum SpeakerRepairService {
    /// The label a collapsed transcript uses for every remote voice. Segments
    /// carrying anything else — "Me", "Speaker 2", a person's name — are left
    /// alone, so a repair can't undo a real attribution or a manual edit.
    static var collapsedLabel: String { Speaker.unidentifiedLabel }

    enum Outcome: Equatable {
        case repaired(voices: Int, segments: Int)
        /// Diarization heard one voice in a collapsed transcript. Numbering
        /// it adds nothing over "Speaker", so the transcript is left as it is.
        case singleVoice
        /// Listening again to an over-split candidate heard no fewer voices
        /// than the transcript already shows. Nothing is folded: the labels
        /// may be right, and shuffling numbers around would only be churn.
        case unchanged
        /// The audio has been pruned by the retention sweep. Nothing to do,
        /// and nothing that can be done.
        case audioUnavailable
        case notACandidate
        case failed(String)
    }

    /// Attributed speech below which a numbered voice looks like a split
    /// rather than a person. Generous on purpose: this only nominates a
    /// meeting for a second listen, and the fold is applied only if that
    /// listen hears fewer voices. The 13-second backchannel cluster that
    /// prompted this carried 38 seconds of transcript, because a segment
    /// straddling a turn goes to whoever holds most of it.
    static let overSplitSuspectSeconds: TimeInterval = 60

    /// Meetings that would benefit: collapsed attribution, and audio still on
    /// disk to attribute from.
    ///
    /// Yields between meetings. Scanning the library means faulting in every
    /// transcript segment and touching the recordings directory, and the main
    /// actor owns the store — without yielding, the window simply stops
    /// redrawing until the whole scan finishes.
    /// Both counts the settings pane needs, from one walk of the library.
    struct Survey {
        var repairable: [Meeting] = []
        var collapsedCount = 0
        var overSplitCount = 0
        var resettableCount = 0
    }

    static func survey(in context: ModelContext) async -> Survey {
        let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        var survey = Survey()
        for (index, meeting) in meetings.enumerated() {
            if index % 10 == 0 { await Task.yield() }
            if Task.isCancelled { break }
            let classification = classify(meeting)
            if classification.isResettable { survey.resettableCount += 1 }
            if classification.isRepairable, hasSystemAudio(for: meeting) {
                survey.repairable.append(meeting)
                if classification.isCollapsed { survey.collapsedCount += 1 }
                if classification.isOverSplit { survey.overSplitCount += 1 }
            }
        }
        return survey
    }

    /// Whether any system audio survives for a meeting.
    ///
    /// Deliberately not `systemChunks(for:)`: that opens every chunk with
    /// `AVAudioFile` to read its duration so it can resolve a split meeting's
    /// window. Across the library that is tens of thousands of file opens, and
    /// answering "is there audio at all" needs none of them.
    static func hasSystemAudio(for meeting: Meeting) -> Bool {
        let sourceID = meeting.audioSourceMeetingID ?? meeting.id
        let base = StorageManager.shared.systemAudioURL(for: sourceID)
        // Enumerating the chunks would stat every file in the track — five
        // hundred syscalls to answer a yes/no, across every meeting in the
        // library, on the main actor. The first two answer it.
        let fm = FileManager.default
        return fm.fileExists(atPath: base.path)
            || fm.fileExists(atPath: AudioFileWriter.chunkURL(base: base, index: 1).path)
    }

    /// What one meeting's transcript needs, decided in a single pass.
    ///
    /// Both questions require faulting in every segment, and asking them
    /// separately meant walking several hundred thousand objects twice — long
    /// enough that the settings pane sat on a spinner well after the numbers
    /// had appeared.
    struct Classification: Equatable {
        /// Remote speech exists and none of it is attributed.
        var isCollapsed: Bool
        /// Remote voices are numbered, nothing is hand-named, and the
        /// numbering looks like one voice split in two: a numbered voice with
        /// almost nothing to say, or a stray anonymous "Speaker" beside a
        /// single numbered one. A nomination, not a verdict — the repair
        /// applies only if listening again hears fewer voices.
        var isOverSplit: Bool
        /// A previous repair left labels that can be rolled back.
        var isResettable: Bool

        var isRepairable: Bool { isCollapsed || isOverSplit }
    }

    static func classify(_ meeting: Meeting) -> Classification {
        var sawCollapsed = false
        var sawNamed = false
        var resettable = false
        var numberedSeconds: [String: TimeInterval] = [:]

        for segment in meeting.segments {
            // A segment the user edited is theirs; its stash is not ours to
            // roll back.
            if !segment.isEdited, segment.originalSpeakerData != nil {
                resettable = true
            }
            guard case .other(let name) = segment.speaker else { continue }
            if name == collapsedLabel {
                sawCollapsed = true
            } else if segment.speaker.isUnidentified {
                numberedSeconds[name, default: 0] += max(0, segment.endTime - segment.startTime)
            } else {
                sawNamed = true
            }
        }
        // A meeting that has been partly relabelled by hand is left alone
        // entirely — re-running would overwrite that work with numbers.
        guard !sawNamed else {
            return Classification(isCollapsed: false, isOverSplit: false, isResettable: resettable)
        }
        let collapsed = sawCollapsed && numberedSeconds.isEmpty
        let overSplit = !numberedSeconds.isEmpty
            && ((sawCollapsed && numberedSeconds.count == 1)
                || numberedSeconds.values.contains { $0 < overSplitSuspectSeconds })
        return Classification(isCollapsed: collapsed, isOverSplit: overSplit, isResettable: resettable)
    }

    /// Whether a proposed relabelling of the machine-labelled lines is a fold
    /// — fewer distinct voices than before — rather than a reshuffle.
    ///
    /// Over-split repair exists to remove voices that were never there. The
    /// same number of voices with different numbering is not that, and
    /// applying it would rewrite labels the reader may already have learned
    /// for no gain.
    static func isFold(current: [Speaker], proposed: [Speaker]) -> Bool {
        !proposed.isEmpty && Set(proposed).count < Set(current).count
    }

    /// True when the transcript has remote speech and none of it is attributed.
    static func isCollapsed(_ meeting: Meeting) -> Bool {
        classify(meeting).isCollapsed
    }

    /// System-audio chunks for a meeting, resolved exactly as re-processing
    /// resolves them — including the window for a meeting split off another's
    /// recording, whose timeline starts at its own first chunk.
    static func systemChunks(for meeting: Meeting) -> [URL] {
        let storage = StorageManager.shared
        let sourceID = meeting.audioSourceMeetingID ?? meeting.id
        let all = AudioFileWriter.existingChunkURLs(base: storage.systemAudioURL(for: sourceID))
        guard !all.isEmpty else { return [] }
        return ReProcessingQueue.chunks(
            all,
            in: meeting.audioStartOffset...(meeting.audioEndOffset ?? .greatestFiniteMagnitude)
        )
    }

    /// Repair one meeting. The transcript's text and timings are never touched.
    static func repair(
        _ meeting: Meeting,
        in context: ModelContext,
        diarizer: SpeakerDiarizationService? = nil
    ) async -> Outcome {
        let classification = classify(meeting)
        guard classification.isRepairable else { return .notACandidate }
        let chunks = systemChunks(for: meeting)
        guard !chunks.isEmpty else { return .audioUnavailable }

        let diarized: [DiarizedSegment]
        // Reuse the caller's service when there is one: `prepare()` loads
        // CoreML models onto the Neural Engine, and doing that once per
        // meeting meant hundreds of redundant loads across a library repair.
        let service = diarizer ?? SpeakerDiarizationService()
        do {
            try await service.prepare()
            diarized = try await service.diarizeTrack(chunkURLs: chunks)
        } catch is CancellationError {
            return .failed("Cancelled.")
        } catch {
            return .failed(error.localizedDescription)
        }

        if classification.isCollapsed {
            return relabelCollapsed(meeting, diarized: diarized, in: context)
        }
        return foldOverSplit(meeting, diarized: diarized, in: context)
    }

    /// Collapsed: give the anonymous remote lines numbers.
    private static func relabelCollapsed(
        _ meeting: Meeting,
        diarized: [DiarizedSegment],
        in context: ModelContext
    ) -> Outcome {
        // Same pipeline re-processing uses, so a repaired transcript and a
        // freshly-processed one are attributed identically. `minimumVoices: 2`
        // is the one difference that belongs here: renaming a single anonymous
        // voice to "Speaker 1" tells the reader nothing it didn't know.
        guard let attribution = SpeakerIdentification.attribute(
            diarized: diarized,
            meeting: meeting,
            minimumVoices: 2
        ) else { return .singleVoice }

        var relabelled = 0
        for segment in meeting.segments {
            guard case .other(let name) = segment.speaker, name == collapsedLabel else { continue }
            guard let speaker = attribution.speaker(from: segment.startTime, to: segment.endTime) else { continue }
            stash(segment)
            segment.speaker = speaker
            relabelled += 1
        }
        guard relabelled > 0 else { return .singleVoice }
        return commit(meeting, in: context, voices: attribution.voiceCount, relabelled: relabelled)
    }

    /// Over-split: re-attribute every machine-labelled remote line, and keep
    /// the result only if it has fewer voices than the transcript shows now.
    ///
    /// `minimumVoices: 1` here, unlike the collapsed path: hearing a single
    /// voice is the whole point when the transcript claims two. A line the
    /// diarizer still can't place keeps the plain "Speaker" label, exactly
    /// as re-processing would leave it.
    private static func foldOverSplit(
        _ meeting: Meeting,
        diarized: [DiarizedSegment],
        in context: ModelContext
    ) -> Outcome {
        guard let attribution = SpeakerIdentification.attribute(
            diarized: diarized,
            meeting: meeting,
            minimumVoices: 1
        ) else { return .unchanged }

        let candidates = meeting.segments.filter(\.speaker.isUnidentified)
        let proposed = candidates.map {
            attribution.speaker(from: $0.startTime, to: $0.endTime) ?? .unidentified
        }
        guard isFold(current: candidates.map(\.speaker), proposed: proposed) else { return .unchanged }

        var relabelled = 0
        for (segment, speaker) in zip(candidates, proposed) where segment.speaker != speaker {
            stash(segment)
            segment.speaker = speaker
            relabelled += 1
        }
        guard relabelled > 0 else { return .unchanged }
        return commit(meeting, in: context, voices: attribution.voiceCount, relabelled: relabelled)
    }

    /// Stash the pre-repair label so this is reversible. Deliberately without
    /// setting `isEdited`: that flag means "the user changed this" and drives
    /// a badge, and a machine relabel shouldn't claim to be their work. If
    /// they later edit the segment themselves, the stash is replaced with the
    /// repaired value — which is the right revert target for them anyway.
    private static func stash(_ segment: TranscriptSegment) {
        if !segment.isEdited, segment.originalSpeakerData == nil {
            segment.originalSpeakerData = segment.speakerData
        }
    }

    private static func commit(
        _ meeting: Meeting,
        in context: ModelContext,
        voices: Int,
        relabelled: Int
    ) -> Outcome {
        PersistenceGate.save(
            context,
            site: "SpeakerRepair.relabel",
            critical: false,
            meetingID: meeting.id
        )
        // Indexed snippets embed the speaker name — "Speaker: we can't turn
        // that on" — so leaving them alone would have Ask quoting the old
        // attribution back at the user. Dropping the records lets the launch
        // backfill re-index the meeting with the names it now has.
        invalidateSearchIndex(for: meeting)
        return .repaired(voices: voices, segments: relabelled)
    }

    /// Undo a repair, restoring the labels the transcript had before it.
    ///
    /// Exists because a repair is otherwise one-way: once segments read
    /// "Speaker 2" they no longer look collapsed, so neither this service nor
    /// a future improved diarizer would ever revisit them. Resetting makes the
    /// meeting a candidate again.
    @discardableResult
    static func resetLabels(for meeting: Meeting, in context: ModelContext) -> Int {
        var reverted = 0
        for segment in meeting.segments {
            // Never touch a segment the user edited — their label is not ours
            // to roll back.
            guard !segment.isEdited, let original = segment.originalSpeakerData else { continue }
            segment.speakerData = original
            segment.originalSpeakerData = nil
            reverted += 1
        }
        guard reverted > 0 else { return 0 }
        PersistenceGate.save(
            context,
            site: "SpeakerRepair.reset",
            critical: false,
            meetingID: meeting.id
        )
        invalidateSearchIndex(for: meeting)
        return reverted
    }

    /// True when a repair left something to undo.
    static func canResetLabels(_ meeting: Meeting) -> Bool {
        classify(meeting).isResettable
    }

    /// Shared with speaker identification, which invalidates for the same
    /// reason: indexed snippets embed the speaker name.
    static func invalidateSearchIndex(for meeting: Meeting) {
        guard let store = EmbeddingStore.shared else { return }
        let removed = store.deleteRecords(forMeetingID: meeting.id)
        if removed > 0 {
            LogManager.send(
                "Speaker repair: dropped \(removed) search record(s) for \"\(meeting.title)\" so they re-index with the new speakers",
                category: .transcription,
                meetingID: meeting.id
            )
        }
    }

    /// Repair every candidate, oldest first so a long run makes visible
    /// progress through the backlog rather than picking at random.
    /// `meetings` lets a caller that has already surveyed the library pass its
    /// result in. The settings pane has one on screen to show the count, and
    /// re-deriving it here walked every segment in the library a second time.
    static func repairAll(
        in context: ModelContext,
        meetings candidates: [Meeting]? = nil,
        onProgress: @MainActor (Int, Int) -> Void
    ) async -> (repaired: Int, skipped: Int) {
        let pool: [Meeting]
        if let candidates {
            pool = candidates
        } else {
            pool = await survey(in: context).repairable
        }
        let meetings = pool.sorted { $0.date < $1.date }
        var repaired = 0
        var skipped = 0
        // One service for the whole run.
        let diarizer = SpeakerDiarizationService()

        LogManager.send("Speaker repair: \(meetings.count) meeting(s) with collapsed or over-split voices", category: .transcription)
        for (index, meeting) in meetings.enumerated() {
            if Task.isCancelled { break }
            onProgress(index, meetings.count)
            // The diarizer runs on the Neural Engine, which a live recording
            // needs more than a backlog repair does.
            guard ReProcessingQueue.shared.current == nil else {
                LogManager.send("Speaker repair: paused, re-processing is running", category: .transcription)
                break
            }
            switch await repair(meeting, in: context, diarizer: diarizer) {
            case .repaired(let voices, let segments):
                repaired += 1
                LogManager.send(
                    "Speaker repair: \"\(meeting.title)\" — \(voices) voices across \(segments) segment(s)",
                    category: .transcription,
                    meetingID: meeting.id
                )
            case .singleVoice, .unchanged, .audioUnavailable, .notACandidate:
                skipped += 1
            case .failed(let message):
                skipped += 1
                LogManager.send(
                    "Speaker repair failed for \"\(meeting.title)\": \(message)",
                    category: .transcription,
                    level: .warning,
                    meetingID: meeting.id
                )
            }
        }
        onProgress(meetings.count, meetings.count)
        LogManager.send("Speaker repair complete: \(repaired) repaired, \(skipped) skipped", category: .transcription)
        return (repaired, skipped)
    }
}

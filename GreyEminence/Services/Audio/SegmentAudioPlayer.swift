// `@preconcurrency`: CI's older SDK does not mark `AVAssetTrack` Sendable, so
// `loadTracks(withMediaType:)` awaited from the nonisolated composition
// builder fails strict-concurrency checking there while compiling clean
// locally. Same divergence and same fix as ScreenShareCaptureService.
@preconcurrency import AVFoundation
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Plays the recorded audio behind one transcript segment.
///
/// Built for a diagnostic question — "is the audio bad, or is the transcript
/// bad?" — so it plays the track the words actually came from: the
/// microphone for the user's own segments, system audio for everyone else.
/// Mixing the two would hide exactly the difference being listened for; the
/// user can still pick a track explicitly.
///
/// One player, app-wide: starting a segment stops whatever was playing.
@Observable
@MainActor
final class SegmentAudioPlayer {

    static let shared = SegmentAudioPlayer()

    enum Track: String, CaseIterable, Identifiable {
        /// Microphone for "Me", system audio for everyone else.
        case speaker
        case mic
        case system
        case both

        var id: String { rawValue }

        var label: String {
            switch self {
            case .speaker: "Speaker's own track"
            case .mic: "Microphone only"
            case .system: "System audio only"
            case .both: "Both, mixed"
            }
        }
    }

    static let trackKey = "segmentPlaybackTrack"

    /// The segment currently playing, for the row that started it.
    private(set) var playingSegmentID: UUID?
    /// Why the last attempt could not play, keyed to the segment it was for.
    private(set) var failure: (segmentID: UUID, message: String)?

    var track: Track {
        didSet { UserDefaults.standard.set(track.rawValue, forKey: Self.trackKey) }
    }

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.trackKey) ?? ""
        track = Track(rawValue: stored) ?? .speaker
    }

    func toggle(_ segment: TranscriptSegment, in meeting: Meeting) {
        if playingSegmentID == segment.id {
            stop()
        } else {
            play(segment, in: meeting)
        }
    }

    /// Everything the asset work needs, read off the models on the main
    /// actor so the composition builder never touches SwiftData.
    private struct Request: Sendable {
        let window: ClosedRange<TimeInterval>
        let bases: [URL]
    }

    private func request(for segment: TranscriptSegment, in meeting: Meeting) -> Request {
        let sourceMeetingID = meeting.audioSourceMeetingID ?? meeting.id
        let window = SegmentAudioLocator.window(
            segmentStart: segment.startTime,
            segmentEnd: segment.endTime,
            offset: meeting.audioStartOffset
        )
        let storage = StorageManager.shared
        let bases = Self.sources(for: track, isMe: segment.speaker.isMe).map { source in
            source == .mic
                ? storage.micAudioURL(for: sourceMeetingID)
                : storage.systemAudioURL(for: sourceMeetingID)
        }
        return Request(window: window, bases: bases)
    }

    func play(_ segment: TranscriptSegment, in meeting: Meeting) {
        stop()
        failure = nil

        let segmentID = segment.id
        let request = request(for: segment, in: meeting)

        playingSegmentID = segmentID
        loadTask = Task { [weak self] in
            do {
                let item = AVPlayerItem(asset: try await Self.makeComposition(window: request.window, bases: request.bases))
                guard let self, !Task.isCancelled, self.playingSegmentID == segmentID else { return }
                self.start(item, segmentID: segmentID)
            } catch {
                guard let self, self.playingSegmentID == segmentID else { return }
                self.playingSegmentID = nil
                self.failure = (segmentID, error.localizedDescription)
                LogManager.send(
                    "Segment playback failed: \(error.localizedDescription)",
                    category: .audio,
                    level: .warning,
                    meetingID: meeting.id
                )
            }
        }
    }

    // MARK: - Export

    /// Save the same audio the play button would play as an .m4a, where the
    /// user chooses. Same track choice as playback, so what they hear is what
    /// they get.
    func export(_ segment: TranscriptSegment, in meeting: Meeting) {
        let segmentID = segment.id
        let request = request(for: segment, in: meeting)
        let meetingID = meeting.id
        let suggestedName = Self.clipFilename(
            meetingTitle: meeting.title,
            segmentStart: segment.startTime,
            speaker: segment.speaker.displayName
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.title = "Save Audio Clip"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        failure = nil
        Task { [weak self] in
            do {
                let composition = try await Self.makeComposition(window: request.window, bases: request.bases)
                try await Self.write(composition, to: destination)
                LogManager.send("Saved audio clip \(destination.lastPathComponent)", category: .audio, meetingID: meetingID)
            } catch {
                self?.failure = (segmentID, "Could not save clip: \(error.localizedDescription)")
                LogManager.send(
                    "Audio clip export failed: \(error.localizedDescription)",
                    category: .audio,
                    level: .warning,
                    meetingID: meetingID
                )
            }
        }
    }

    /// "Meeting 2026-09-14, 3.42 PM — 12m34s Speaker 2.m4a". Colons and
    /// slashes go: Finder shows a colon as a slash and a slash is a path.
    nonisolated static func clipFilename(meetingTitle: String, segmentStart: TimeInterval, speaker: String) -> String {
        let minutes = Int(segmentStart) / 60
        let seconds = Int(segmentStart) % 60
        let stamp = minutes >= 60
            ? String(format: "%dh%02dm%02ds", minutes / 60, minutes % 60, seconds)
            : String(format: "%dm%02ds", minutes, seconds)
        let raw = "\(meetingTitle) \u{2014} \(stamp) \(speaker)"
        let cleaned = raw
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(200)) + ".m4a"
    }

    enum ExportError: LocalizedError {
        case noExporter
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noExporter: "The audio could not be prepared for export"
            case .failed(let why): why
            }
        }
    }

    private static func write(_ composition: AVMutableComposition, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.noExporter
        }
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .m4a
        await session.export()
        if let error = session.error {
            throw ExportError.failed(error.localizedDescription)
        }
        if session.status != .completed {
            throw ExportError.failed("export ended with status \(session.status.rawValue)")
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        player?.pause()
        player = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        playingSegmentID = nil
    }

    // MARK: - Internals

    /// Which recorded tracks to play for a segment.
    static func sources(for track: Track, isMe: Bool) -> [Track] {
        switch track {
        case .speaker: isMe ? [.mic] : [.system]
        case .mic: [.mic]
        case .system: [.system]
        case .both: [.mic, .system]
        }
    }

    private func start(_ item: AVPlayerItem, segmentID: UUID) {
        let player = AVPlayer(playerItem: item)
        self.player = player
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playingSegmentID == segmentID else { return }
                self.stop()
            }
        }
        player.play()
    }

    enum PlaybackError: LocalizedError {
        case noAudio

        var errorDescription: String? {
            "No recorded audio on disk for this segment"
        }
    }

    /// A composition holding the requested tracks' slices, laid end to end
    /// so a segment that straddles a chunk boundary plays through. Shared by
    /// playback and export so a saved clip is exactly what was heard.
    private static func makeComposition(
        window: ClosedRange<TimeInterval>,
        bases: [URL]
    ) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        var insertedAnything = false

        for base in bases {
            let chunks = AudioFileWriter.existingChunkURLs(base: base)
            let slices = SegmentAudioLocator.slices(covering: window, chunks: chunks) {
                HighQualityTranscriber.assumedDuration(of: $0, fallback: 10)
            }
            guard !slices.isEmpty,
                  let track = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }

            var cursor = CMTime.zero
            for slice in slices {
                let asset = AVURLAsset(url: slice.url)
                guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let range = CMTimeRange(
                    start: CMTime(seconds: slice.start, preferredTimescale: 600),
                    duration: CMTime(seconds: slice.duration, preferredTimescale: 600)
                )
                try track.insertTimeRange(range, of: assetTrack, at: cursor)
                cursor = cursor + range.duration
                insertedAnything = true
            }
        }

        guard insertedAnything else { throw PlaybackError.noAudio }
        return composition
    }
}

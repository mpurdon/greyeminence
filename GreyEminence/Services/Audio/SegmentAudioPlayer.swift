import AVFoundation
import Foundation

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

    func play(_ segment: TranscriptSegment, in meeting: Meeting) {
        stop()
        failure = nil

        // Everything the load needs, read off the models here on the main
        // actor so the asset work below never touches SwiftData.
        let segmentID = segment.id
        let sourceMeetingID = meeting.audioSourceMeetingID ?? meeting.id
        let window = SegmentAudioLocator.window(
            segmentStart: segment.startTime,
            segmentEnd: segment.endTime,
            offset: meeting.audioStartOffset
        )
        let sources = Self.sources(for: track, isMe: segment.speaker.isMe)
        let storage = StorageManager.shared
        let bases: [(Track, URL)] = sources.map { source in
            (source, source == .mic
                ? storage.micAudioURL(for: sourceMeetingID)
                : storage.systemAudioURL(for: sourceMeetingID))
        }

        playingSegmentID = segmentID
        loadTask = Task { [weak self] in
            do {
                let item = try await Self.makeItem(window: window, bases: bases)
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
    /// so a segment that straddles a chunk boundary plays through.
    private static func makeItem(
        window: ClosedRange<TimeInterval>,
        bases: [(Track, URL)]
    ) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        var insertedAnything = false

        for (_, base) in bases {
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
        return AVPlayerItem(asset: composition)
    }
}

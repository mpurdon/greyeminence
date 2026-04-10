import AVFoundation
import Foundation

/// Validates audio chunks on disk and quarantines broken ones.
///
/// Context: `AudioFileWriter` writes audio in chunks (mic.m4a, mic.part001.m4a,
/// …) so a crash bounds the loss window. But each chunk's playability depends
/// on whether the AAC container was properly finalized — which only happens
/// when the file is closed cleanly. If a recording was interrupted mid-chunk,
/// the last chunk's metadata may be broken and AVFoundation won't play it.
///
/// This service is called from `resumeInterruptedRecording` before capture
/// restarts. It walks the chunks, probes each with `AVAsset.load(.isPlayable)`,
/// and renames broken ones to `<name>.corrupted` so they're preserved for
/// forensic recovery but excluded from normal playback.
enum AudioChunkValidator {
    struct Result: Sendable {
        let valid: [URL]
        let corrupted: [URL]
    }

    /// Probe all existing chunks for the given base URL. Broken chunks are
    /// renamed to `<name>.corrupted` (the extension is appended, not replaced,
    /// so `mic.part003.m4a.corrupted`). Returns the partition of valid vs.
    /// corrupted URLs for logging.
    static func validateChunks(base: URL) async -> Result {
        let urls = AudioFileWriter.existingChunkURLs(base: base)
        var valid: [URL] = []
        var corrupted: [URL] = []

        for url in urls {
            if await isPlayable(url) {
                valid.append(url)
            } else {
                let quarantined = url.appendingPathExtension("corrupted")
                // If a prior run already quarantined this file, skip the rename
                // and just record it as corrupted.
                if FileManager.default.fileExists(atPath: quarantined.path) {
                    corrupted.append(url)
                    continue
                }
                do {
                    try FileManager.default.moveItem(at: url, to: quarantined)
                    corrupted.append(quarantined)
                } catch {
                    // If we can't rename it, leave it in place but record the
                    // original URL as corrupted so the caller knows.
                    LogManager.send(
                        "Failed to quarantine broken audio chunk \(url.lastPathComponent): \(error.localizedDescription)",
                        category: .audio,
                        level: .warning
                    )
                    corrupted.append(url)
                }
            }
        }

        if !corrupted.isEmpty {
            LogManager.send(
                "Audio chunk validation: \(valid.count) valid, \(corrupted.count) corrupted",
                category: .audio,
                level: .warning
            )
        } else if !valid.isEmpty {
            LogManager.send(
                "Audio chunk validation: \(valid.count) valid, none corrupted",
                category: .audio
            )
        }

        return Result(valid: valid, corrupted: corrupted)
    }

    // MARK: - Private

    private static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            guard playable else { return false }
            // Also require a non-zero duration — a zero-byte or
            // header-only file may report playable on some codecs.
            let duration = try await asset.load(.duration)
            return duration.seconds > 0
        } catch {
            return false
        }
    }
}

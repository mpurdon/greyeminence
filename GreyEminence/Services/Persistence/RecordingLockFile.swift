import Foundation

/// A sidecar marker file written to the meeting's recording directory while
/// capture is active. Belt-and-suspenders backup to the `activeRecordingMeetingID`
/// UserDefaults breadcrumb.
///
/// Why both: UserDefaults can be wiped by the user, corrupted, or silently reset
/// by the OS. The lock file lives alongside the audio chunks on disk, so as long
/// as the audio exists, we have a record of what meeting it belonged to. This
/// protects the forensic recovery path — even if the SwiftData `Meeting` row
/// never saved, we can tell the user "we found unclaimed audio from YYYY-MM-DD".
///
/// Format is plain JSON so the user can inspect it in Finder / TextEdit.
enum RecordingLockFile {
    struct Payload: Codable, Sendable {
        let meetingID: UUID
        let startedAt: Date
        let isInterviewMeeting: Bool
        /// Bumped when the file format changes — the reader tolerates unknown
        /// future versions by returning nil instead of throwing.
        let schemaVersion: Int

        init(meetingID: UUID, startedAt: Date = .now, isInterviewMeeting: Bool = false) {
            self.meetingID = meetingID
            self.startedAt = startedAt
            self.isInterviewMeeting = isInterviewMeeting
            self.schemaVersion = 1
        }
    }

    /// Write a fresh lock file. Safe to call multiple times — overwrites.
    static func write(for meetingID: UUID, isInterviewMeeting: Bool = false) {
        let url = lockURL(for: meetingID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Payload(
                meetingID: meetingID,
                isInterviewMeeting: isInterviewMeeting
            ))
            try data.write(to: url, options: .atomic)
            LogManager.send("Recording lock file written: \(meetingID)", category: .audio)
        } catch {
            LogManager.send("Recording lock file write failed: \(error.localizedDescription)", category: .audio, level: .warning)
        }
    }

    /// Remove the lock file after a clean stop. Missing file is not an error.
    static func remove(for meetingID: UUID) {
        let url = lockURL(for: meetingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            LogManager.send("Recording lock file remove failed: \(error.localizedDescription)", category: .audio, level: .warning)
        }
    }

    /// Walk every `Recordings/<uuid>/recording.lock` file still on disk and
    /// return its payload. Used on launch to detect meetings that were mid-
    /// recording when the app died.
    static func scanAll() -> [Payload] {
        let recordingsRoot = StorageManager.shared.recordingsURL
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var found: [Payload] = []
        for dir in dirs {
            let url = dir.appendingPathComponent(lockFileName)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let payload = try? decoder.decode(Payload.self, from: data) else {
                continue
            }
            found.append(payload)
        }
        return found
    }

    // MARK: - Private

    private static let lockFileName = "recording.lock"

    private static func lockURL(for meetingID: UUID) -> URL {
        StorageManager.shared
            .recordingDirectory(for: meetingID)
            .appendingPathComponent(lockFileName)
    }
}

import Foundation

@Observable
final class StorageManager: Sendable {
    static let shared = StorageManager()

    let appSupportURL: URL
    let recordingsURL: URL
    let modelsURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GreyEminence", isDirectory: true)
        self.appSupportURL = base
        self.recordingsURL = base.appendingPathComponent("Recordings", isDirectory: true)
        self.modelsURL = base.appendingPathComponent("Models", isDirectory: true)

        for url in [base, recordingsURL, modelsURL] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func recordingDirectory(for meetingID: UUID) -> URL {
        let dir = recordingsURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func micAudioURL(for meetingID: UUID) -> URL {
        recordingDirectory(for: meetingID).appendingPathComponent("mic.m4a")
    }

    func systemAudioURL(for meetingID: UUID) -> URL {
        recordingDirectory(for: meetingID).appendingPathComponent("system.m4a")
    }

    /// Remove the entire recording directory for a meeting (mic + system
    /// chunks, plus any sidecar files). Silent on failure — missing-file is
    /// not an error here.
    @discardableResult
    func deleteRecording(for meetingID: UUID) -> Bool {
        let dir = recordingsURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        do {
            try FileManager.default.removeItem(at: dir)
            return true
        } catch {
            return false
        }
    }

    /// Sweep the Recordings directory and remove any per-meeting folder whose
    /// UUID isn't referenced by the provided set (meeting IDs +
    /// `audioSourceMeetingID` of split meetings). Returns the number of
    /// directories removed and the total bytes freed.
    func purgeOrphanedRecordings(referencedIDs: Set<UUID>) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: recordingsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var count = 0
        var bytes: Int64 = 0
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, let uuid = UUID(uuidString: entry.lastPathComponent) else { continue }
            if referencedIDs.contains(uuid) { continue }

            let size = directorySize(at: entry)
            do {
                try fm.removeItem(at: entry)
                count += 1
                bytes += size
            } catch {
                // Skip on failure; next launch will try again.
            }
        }
        return (count, bytes)
    }

    private func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }
}

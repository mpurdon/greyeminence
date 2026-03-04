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
}

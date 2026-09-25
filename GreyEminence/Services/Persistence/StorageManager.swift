import Foundation

@Observable
final class StorageManager: Sendable {
    static let shared = StorageManager()

    let appSupportURL: URL
    let recordingsURL: URL
    let modelsURL: URL
    let candidatesURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GreyEminence", isDirectory: true)
        self.appSupportURL = base
        self.recordingsURL = base.appendingPathComponent("Recordings", isDirectory: true)
        self.modelsURL = base.appendingPathComponent("Models", isDirectory: true)
        self.candidatesURL = base.appendingPathComponent("Candidates", isDirectory: true)

        for url in [base, recordingsURL, modelsURL, candidatesURL] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Path only — never creates. Read paths must use this: asking
    /// `recordingDirectory` for a URL creates the folder as a side effect, so
    /// merely *probing* for a sidecar left an empty directory behind for every
    /// meeting checked. The retention sweep then "removed audio" for hundreds
    /// of meetings a launch while freeing 0.0 MB, because all it was deleting
    /// was folders the probe had just made.
    func recordingDirectoryPath(for meetingID: UUID) -> URL {
        recordingsURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }

    func recordingDirectory(for meetingID: UUID) -> URL {
        let dir = recordingsURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func micAudioURL(for meetingID: UUID) -> URL {
        recordingDirectoryPath(for: meetingID).appendingPathComponent("mic.m4a")
    }

    func systemAudioURL(for meetingID: UUID) -> URL {
        recordingDirectoryPath(for: meetingID).appendingPathComponent("system.m4a")
    }

    /// Sidecar file used by the re-processing pipeline to checkpoint
    /// progress between chunks so an interrupted job (live-recording
    /// yield, app restart) can resume instead of restarting from chunk 0.
    func reProcessCheckpointURL(for meetingID: UUID) -> URL {
        recordingDirectoryPath(for: meetingID).appendingPathComponent("reprocess-checkpoint.json")
    }

    func loadReProcessCheckpoint(for meetingID: UUID) -> ReProcessingCheckpoint? {
        let url = reProcessCheckpointURL(for: meetingID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cp = try? JSONDecoder().decode(ReProcessingCheckpoint.self, from: data) else { return nil }
        guard cp.version == ReProcessingCheckpoint.currentVersion else { return nil }
        return cp
    }

    func saveReProcessCheckpoint(_ checkpoint: ReProcessingCheckpoint, for meetingID: UUID) {
        let url = reProcessCheckpointURL(for: meetingID)
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func deleteReProcessCheckpoint(for meetingID: UUID) {
        try? FileManager.default.removeItem(at: reProcessCheckpointURL(for: meetingID))
    }

    // MARK: - Sidecars

    /// Read a JSON sidecar, treating any failure as absent.
    ///
    /// These files are all derived data — a corrupt or half-written one should
    /// cost a recomputation, never an error the caller has to handle.
    func loadSidecar<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func saveSidecar<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Derived per-meeting data that must outlive the audio.
    ///
    /// Not in the recording directory: the retention sweep deletes that
    /// wholesale, and these files are the reason a meeting can still be worked
    /// with once its audio is gone. Putting a voice signature next to the
    /// recording would have purged it in the same pass — silently removing the
    /// ability to identify speakers in exactly the older meetings most likely
    /// to need it.
    private var derivedURL: URL {
        let dir = appSupportURL.appendingPathComponent("Derived", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// How many search records a meeting *should* have, recorded when it was
    /// last indexed.
    ///
    /// Exists so the launch sweep can spot partial coverage without rebuilding
    /// each meeting's work list — which meant chunking and sorting every
    /// transcript in the library on the main actor, and froze the app for as
    /// long as that took.
    struct SearchCoverage: Codable, Sendable {
        let modelIdentifier: String
        let expectedRecords: Int
    }

    func searchCoverageURL(for meetingID: UUID) -> URL {
        derivedURL.appendingPathComponent("\(meetingID.uuidString)-coverage.json")
    }

    func loadSearchCoverage(for meetingID: UUID) -> SearchCoverage? {
        loadSidecar(SearchCoverage.self, at: searchCoverageURL(for: meetingID))
    }

    func saveSearchCoverage(_ coverage: SearchCoverage, for meetingID: UUID) {
        saveSidecar(coverage, to: searchCoverageURL(for: meetingID))
    }

    /// Voice signatures for a meeting's diarization clusters.
    ///
    /// A sidecar beside the recording: derived from audio, recomputable, and
    /// kept out of the store so changing how signatures are built doesn't mean
    /// a schema migration.
    func voiceClustersURL(for meetingID: UUID) -> URL {
        derivedURL.appendingPathComponent("\(meetingID.uuidString)-voices.json")
    }

    func loadVoiceClusters(for meetingID: UUID) -> MeetingVoiceClusters? {
        guard let stored = loadSidecar(MeetingVoiceClusters.self, at: voiceClustersURL(for: meetingID)),
              stored.isCurrent else { return nil }
        return stored
    }

    func saveVoiceClusters(_ clusters: MeetingVoiceClusters, for meetingID: UUID) {
        saveSidecar(clusters, to: voiceClustersURL(for: meetingID))
    }

    /// The latest refinement report for a meeting. Derived, like the voice
    /// signatures, so it survives the audio retention sweep: it is built
    /// from the transcript, which outlives the audio.
    func refinementReportURL(for meetingID: UUID) -> URL {
        derivedURL.appendingPathComponent("\(meetingID.uuidString)-refinement.json")
    }

    /// Every report for a meeting, one per refined feature. A file written
    /// when a meeting could hold only one report reads back as that report
    /// under the legacy key.
    func loadRefinementShelf(for meetingID: UUID) -> RefinementReportShelf {
        let url = refinementReportURL(for: meetingID)
        if let shelf = loadSidecar(RefinementReportShelf.self, at: url) { return shelf }
        if let single = loadSidecar(RefinementReport.self, at: url) {
            return RefinementReportShelf(reports: [RefinementReportShelf.legacyKey: single])
        }
        return RefinementReportShelf()
    }

    func saveRefinementShelf(_ shelf: RefinementReportShelf, for meetingID: UUID) {
        saveSidecar(shelf, to: refinementReportURL(for: meetingID))
    }

    /// Every meeting topic's category and aliases, library-wide. Derived
    /// from the stored insights, so a sidecar rather than a schema version:
    /// an older build opened on the same data loses nothing.
    var topicCatalogURL: URL {
        derivedURL.appendingPathComponent("topic-catalog.json")
    }

    func loadTopicCatalog() -> TopicCatalog {
        loadSidecar(TopicCatalog.self, at: topicCatalogURL) ?? TopicCatalog()
    }

    func saveTopicCatalog(_ catalog: TopicCatalog) {
        saveSidecar(catalog, to: topicCatalogURL)
    }

    /// Cached report figure-anchoring plan. A sidecar file rather than a
    /// SwiftData field: it is derived data that can always be recomputed, so
    /// storing it here buys the cache without a schema version bump.
    func reportAnchorPlanURL(for meetingID: UUID) -> URL {
        recordingDirectoryPath(for: meetingID).appendingPathComponent("report-anchors.json")
    }

    /// Returns the plan only if it was computed against `insightID` — a
    /// regenerated analysis produces different sections, so an older plan
    /// would anchor figures to headings that no longer exist.
    func loadReportAnchorPlan(for meetingID: UUID, insightID: UUID) -> ReportAnchorPlan? {
        guard let plan = loadSidecar(ReportAnchorPlan.self, at: reportAnchorPlanURL(for: meetingID)),
              plan.isValid(forInsight: insightID) else { return nil }
        return plan
    }

    func saveReportAnchorPlan(_ plan: ReportAnchorPlan, for meetingID: UUID) {
        saveSidecar(plan, to: reportAnchorPlanURL(for: meetingID))
    }

    /// Remove the entire recording directory for a meeting (mic + system
    /// chunks, plus any sidecar files). Returns true if something was
    /// actually removed. Missing-file is not an error.
    @discardableResult
    func deleteRecording(for meetingID: UUID) -> Bool {
        let dir = recordingsURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: dir)
            return true
        } catch CocoaError.fileNoSuchFile {
            return false
        } catch {
            return false
        }
    }

    /// Delete the recording folders of any meeting older than `days` whose
    /// completion date is in the supplied map. Audio is purged but the
    /// meeting row + transcript stay — only the (large) m4a files go.
    /// `days <= 0` is a no-op (keep forever).
    func purgeRecordingsOlderThan(
        days: Int,
        meetingFinishedAt: [UUID: Date]
    ) -> (count: Int, bytes: Int64) {
        guard days > 0 else { return (0, 0) }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let fm = FileManager.default
        var count = 0
        var bytes: Int64 = 0
        for (meetingID, finishedAt) in meetingFinishedAt where finishedAt < cutoff {
            let dir = recordingsURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else { continue }
            let size = directorySize(at: dir)
            do {
                try fm.removeItem(at: dir)
                count += 1
                bytes += size
            } catch {
                // Skip on failure; next launch will retry.
            }
        }
        return (count, bytes)
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

    // MARK: - Screen-Share Frames

    /// Per-meeting directory for captured screen-share frames. Lives inside
    /// the recording directory, so deletion/purge/orphan cleanup of the
    /// meeting folder covers frames with no extra work. Created lazily.
    func framesDirectory(for meetingID: UUID) -> URL {
        let dir = recordingDirectory(for: meetingID).appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolve a `ScreenShareFrame.imagePath` (relative to the recording
    /// directory) to an on-disk URL. Doesn't check existence.
    func frameURL(for meetingID: UUID, relativePath: String) -> URL {
        recordingDirectoryPath(for: meetingID).appendingPathComponent(relativePath)
    }

    /// Write one frame's JPEG data and return the path relative to the
    /// recording directory (what `ScreenShareFrame.imagePath` stores).
    /// Frames are grouped by a session-directory (first 8 hex chars of the
    /// session UUID) to keep listings manageable.
    func writeFrame(_ jpeg: Data, meetingID: UUID, sessionID: UUID, sequence: Int) throws -> String {
        let sessionDir = String(sessionID.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let relative = "frames/\(sessionDir)/\(String(format: "%06d", sequence)).jpg"
        let url = recordingDirectory(for: meetingID).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try jpeg.write(to: url, options: .atomic)
        return relative
    }

    /// Remove specific frame image files (paths relative to the recording
    /// directory, i.e. `ScreenShareFrame.imagePath`) and prune any session
    /// subdirs and the `frames/` dir left empty afterward. Returns the number
    /// of files actually removed.
    ///
    /// Needed when a frame-owning meeting is deleted but its recording folder
    /// has to stay on disk because a split sibling still references the shared
    /// source audio — `deleteRecording(for:)` is skipped in that case, so the
    /// JPEGs would otherwise linger until the whole audio group is gone. Static
    /// with an explicit base dir so it's unit-testable off a temp directory.
    @discardableResult
    static func deleteFrameFiles(inRecordingDirectory recordingDir: URL, relativePaths: [String]) -> Int {
        let fm = FileManager.default
        var removed = 0
        var sessionDirs: Set<URL> = []
        for relative in relativePaths {
            let url = recordingDir.appendingPathComponent(relative)
            if (try? fm.removeItem(at: url)) != nil {
                removed += 1
                sessionDirs.insert(url.deletingLastPathComponent())
            }
        }
        // Prune the per-session subdirs, then the frames/ dir, if now empty.
        for dir in sessionDirs {
            if let entries = try? fm.contentsOfDirectory(atPath: dir.path), entries.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
        let framesDir = recordingDir.appendingPathComponent("frames", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(atPath: framesDir.path), entries.isEmpty {
            try? fm.removeItem(at: framesDir)
        }
        return removed
    }

    /// Convenience over ``deleteFrameFiles(inRecordingDirectory:relativePaths:)``
    /// that resolves the recording directory for `sourceMeetingID` (the audio
    /// source — where frames physically live) WITHOUT the mkdir side effect of
    /// `recordingDirectory(for:)`.
    @discardableResult
    func deleteFrameFiles(sourceMeetingID: UUID, relativePaths: [String]) -> Int {
        let dir = recordingsURL.appendingPathComponent(sourceMeetingID.uuidString, isDirectory: true)
        return Self.deleteFrameFiles(inRecordingDirectory: dir, relativePaths: relativePaths)
    }

    // MARK: - Candidate Resumes

    /// Per-candidate directory for attached files (currently just resumes).
    /// Created lazily on first access.
    func candidateDirectory(for candidateID: UUID) -> URL {
        let dir = candidatesURL.appendingPathComponent(candidateID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolved on-disk URL for a candidate's resume, given the stored
    /// filename. Doesn't check existence — callers should verify with
    /// `FileManager.default.fileExists(atPath:)` before using.
    func candidateResumeURL(for candidateID: UUID, filename: String) -> URL {
        candidateDirectory(for: candidateID).appendingPathComponent(filename)
    }

    /// Copy a user-picked file into the candidate's directory and return
    /// the destination filename. Two-phase to avoid losing the prior
    /// resume on failure: copy the new file to a temp name first, only
    /// then atomically replace the prior file. If the copy throws
    /// (permission, disk full), the prior resume stays intact. The source
    /// URL must already have its security scope started by the caller.
    @discardableResult
    func attachResume(sourceURL: URL, candidateID: UUID, replacingFilename: String?) throws -> String {
        let dir = candidateDirectory(for: candidateID)
        let fm = FileManager.default

        // Defensive sanitize — NSOpenPanel doesn't return separator-bearing
        // filenames, but a malformed security-scoped bookmark theoretically could.
        let baseName = sourceURL.lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let destURL = dir.appendingPathComponent(baseName)
        let stagingURL = dir.appendingPathComponent(".staging-\(UUID().uuidString)-\(baseName)")

        try fm.copyItem(at: sourceURL, to: stagingURL)
        do {
            if let prior = replacingFilename {
                try? fm.removeItem(at: dir.appendingPathComponent(prior))
            }
            try? fm.removeItem(at: destURL)
            try fm.moveItem(at: stagingURL, to: destURL)
        } catch {
            try? fm.removeItem(at: stagingURL)
            throw error
        }
        return baseName
    }

    /// Remove a candidate's resume file and clean up the candidate
    /// directory if it's now empty.
    @discardableResult
    func removeResume(candidateID: UUID, filename: String) -> Bool {
        let dir = candidateDirectory(for: candidateID)
        let url = dir.appendingPathComponent(filename)
        let removed = (try? FileManager.default.removeItem(at: url)) != nil
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path), entries.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
        return removed
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

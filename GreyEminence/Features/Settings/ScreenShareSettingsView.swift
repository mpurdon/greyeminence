import SwiftData
import SwiftUI

struct ScreenShareSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(ScreenShareSettings.enabledKey) private var captureEnabled = false
    @AppStorage(ScreenShareSettings.autoDetectKey) private var autoDetect = true
    @AppStorage(ScreenShareSettings.intervalSecondsKey) private var intervalSeconds = ScreenShareSettings.defaultIntervalSeconds
    @AppStorage(ScreenShareSettings.analysisEnabledKey) private var analysisEnabled = true
    @AppStorage(ScreenShareSettings.maxAnalyzedFramesKey) private var maxAnalyzedFrames = ScreenShareSettings.defaultMaxAnalyzedFrames
    private var navigation = SettingsNavigation.shared

    @State private var audioManager = AudioSessionManager()
    @State private var framesBytesOnDisk: Int64?
    @State private var showPurgeConfirmation = false
    @State private var purgeResult: String?

    var body: some View {
        Form {
            captureSection
            analysisSection
            storageSection
            permissionSection
        }
        .formStyle(.grouped)
        .task {
            await audioManager.checkScreenRecordingPermission()
            framesBytesOnDisk = await Self.computeFramesBytes()
        }
    }

    // MARK: - Capture

    private var captureSection: some View {
        Section {
            Toggle(isOn: $captureEnabled) {
                VStack(alignment: .leading) {
                    Text("Capture shared screens during recordings")
                    Text("Screenshots shared content while you record — popped-out Microsoft Teams share windows, and Discord streams that are popped out or fullscreened. Nothing is captured outside a share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $autoDetect) {
                VStack(alignment: .leading) {
                    Text("Auto-detect share windows")
                    Text("When off, use Choose Window in the recording toolbar to pick the window yourself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!captureEnabled)

            HStack {
                Text("Screenshot every")
                Slider(value: $intervalSeconds, in: 5...120, step: 5)
                    .disabled(!captureEnabled)
                Text("\(Int(intervalSeconds))s")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .frame(width: 36, alignment: .trailing)
            }
            Text("Up to ~\(3600 / max(Int(intervalSeconds), 1)) screenshots per hour of continuous sharing. Unchanged frames are discarded, so real volume is usually far lower.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Capture", systemImage: "record.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    // MARK: - AI Analysis

    private var analysisSection: some View {
        Section {
            Toggle(isOn: $analysisEnabled) {
                VStack(alignment: .leading) {
                    Text("Analyze frames with Claude")
                    Text("Sends meaningfully-changed frames to Claude for a short description of what's on screen, using your API key from AI settings. Without this, frames still get on-device text recognition.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!captureEnabled)

            Stepper(value: $maxAnalyzedFrames, in: 10...500, step: 10) {
                LabeledContent("Max analyzed frames per meeting") {
                    Text("\(maxAnalyzedFrames)")
                        .fontDesign(.monospaced)
                }
            }
            .disabled(!captureEnabled || !analysisEnabled)
            Text("Caps Claude usage per meeting. Frames beyond the cap are kept with on-device text only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("Frames are described by \(frameModelLabel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Model and account are in AI settings") {
                    navigation.pane = .ai
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } header: {
            Label("AI Analysis", systemImage: "brain")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    private var frameModelLabel: String {
        let model = ScreenShareSettings.frameAnalysisModel
        let name = model.isEmpty || model == AIModelCatalog.mainModel ? "the meeting-analysis model" : "Haiku 4.5"
        let account = AIAccountSettings.resolved(for: .frameAnalysis)
        return account.isMaster ? name : "\(name) via \(account.profile)"
    }

    // MARK: - Storage & Privacy

    private var storageSection: some View {
        Section {
            LabeledContent("Frames on disk") {
                if let bytes = framesBytesOnDisk {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .fontDesign(.monospaced)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Text("Frames are stored with the meeting's recording and deleted with it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Purge All Captured Frames…", role: .destructive) {
                showPurgeConfirmation = true
            }
            .confirmationDialog(
                "Delete all captured screen-share frames?",
                isPresented: $showPurgeConfirmation
            ) {
                Button("Delete All Frames", role: .destructive) {
                    Task { await purgeAllFrames() }
                }
            } message: {
                Text("Deletes every captured frame image from every meeting. Transcripts, insights, and audio are not affected. This cannot be undone.")
            }
            if let purgeResult {
                Text(purgeResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Storage & Privacy", systemImage: "internaldrive")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    // MARK: - Permission

    private var permissionSection: some View {
        Section {
            LabeledContent("Screen Recording") {
                switch audioManager.screenRecordingPermission {
                case .granted:
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .denied:
                    Label("Not granted", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .unknown:
                    Text("Unknown")
                        .foregroundStyle(.secondary)
                }
            }
            if audioManager.screenRecordingPermission == .denied {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text("The same permission already covers system-audio capture — granting it once enables both.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Permission", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    // MARK: - Frame storage helpers

    /// Total bytes under every meeting's frames/ subdirectory. Walks the
    /// Recordings tree off the main actor.
    private nonisolated static func computeFramesBytes() async -> Int64 {
        let recordingsURL = StorageManager.shared.recordingsURL
        return await Task.detached(priority: .utility) {
            sweepFramesDirectories(under: recordingsURL, removing: false)
        }.value
    }

    /// Synchronous frames-directory walk (NSEnumerator can't be iterated in
    /// async contexts). Returns total bytes found; deletes each frames/
    /// directory after measuring when `removing` is set.
    private nonisolated static func sweepFramesDirectories(under recordingsURL: URL, removing: Bool) -> Int64 {
        let fm = FileManager.default
        guard let meetings = try? fm.contentsOfDirectory(
            at: recordingsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for meetingDir in meetings {
            let framesDir = meetingDir.appendingPathComponent("frames", isDirectory: true)
            guard fm.fileExists(atPath: framesDir.path),
                  let enumerator = fm.enumerator(at: framesDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { continue }
            for case let fileURL as URL in enumerator {
                if let size = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize {
                    total += Int64(size)
                }
            }
            if removing {
                try? fm.removeItem(at: framesDir)
            }
        }
        return total
    }

    /// Delete every frames/ directory and the corresponding SwiftData rows.
    private func purgeAllFrames() async {
        let recordingsURL = StorageManager.shared.recordingsURL
        let removedBytes = await Task.detached(priority: .utility) {
            Self.sweepFramesDirectories(under: recordingsURL, removing: true)
        }.value

        // Remove the rows too so meetings don't reference deleted images.
        let frames = (try? modelContext.fetch(FetchDescriptor<ScreenShareFrame>())) ?? []
        for frame in frames {
            modelContext.delete(frame)
        }
        PersistenceGate.save(modelContext, site: "purgeAllFrames", critical: false, meetingID: nil)

        framesBytesOnDisk = await Self.computeFramesBytes()
        purgeResult = "Removed \(ByteCountFormatter.string(fromByteCount: removedBytes, countStyle: .file)) of frames."
        LogManager.shared.log("Purged all screen-share frames (\(removedBytes) bytes)", category: .screen)
    }
}

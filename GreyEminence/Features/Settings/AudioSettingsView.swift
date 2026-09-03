import SwiftData
import SwiftUI

struct AudioSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var audioManager = AudioSessionManager()
    @State private var monitor = MicLevelMonitor()
    @AppStorage("inputGain") private var inputGain: Double = 1.0
    @AppStorage("autoReprocessMeetings") private var autoReprocessMeetings: Bool = true
    @State private var captureSystemAudio = true

    @State private var isRepairing = false
    @State private var repairDone = 0
    @State private var repairTotal = 0
    /// Held rather than counted: the run reuses this instead of surveying the
    /// library again.
    @State private var repairable: [Meeting] = []
    @State private var repairCollapsed = 0
    @State private var repairOverSplit = 0
    @State private var repairSummary: String?
    @State private var repairResettable = 0
    @State private var isScanning = false

    @MainActor
    private func resetSpeakers() async {
        let meetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
        var reverted = 0
        // No `canResetLabels` pre-check: it walks every segment only for
        // `resetLabels` to walk them again, and `resetLabels` already reports
        // zero when there is nothing to revert. Yields for the same reason the
        // survey does — the main actor owns the store.
        for (index, meeting) in meetings.enumerated() {
            if index % 10 == 0 { await Task.yield() }
            if SpeakerRepairService.resetLabels(for: meeting, in: modelContext) > 0 { reverted += 1 }
        }
        repairSummary = reverted == 0
            ? "Nothing to undo."
            : "Restored the previous labels in \(reverted) meeting\(reverted == 1 ? "" : "s")."
        Task { await refreshRepairCounts() }
    }

    /// Counting means walking every meeting's segments, so it runs as a task
    /// with a visible "checking" state rather than freezing the pane on
    /// appear — which is exactly what it did.
    @MainActor
    private func refreshRepairCounts() async {
        isScanning = true
        defer { isScanning = false }
        let survey = await SpeakerRepairService.survey(in: modelContext)
        // The list itself, not just its count: the button was disabled forever
        // because the survey's candidates were counted here and never kept.
        repairable = survey.repairable
        repairCollapsed = survey.collapsedCount
        repairOverSplit = survey.overSplitCount
        repairResettable = survey.resettableCount
    }

    @MainActor
    private func repairSpeakers() async {
        isRepairing = true
        repairSummary = nil
        defer {
            isRepairing = false
            Task { await refreshRepairCounts() }
        }
        let result = await SpeakerRepairService.repairAll(in: modelContext, meetings: repairable) { done, total in
            repairDone = done
            repairTotal = total
        }
        repairSummary = result.repaired == 0
            ? "Nothing to change — listening again heard the same voices those meetings already show."
            : "Fixed speakers in \(result.repaired) meeting\(result.repaired == 1 ? "" : "s")."
            + (result.skipped > 0 ? " \(result.skipped) left as they were — see the Activity Log." : "")
    }

    /// What the repair button would do, in the reader's terms.
    private var repairDescription: String {
        guard !repairable.isEmpty else {
            return isScanning ? "" : "Every meeting with audio still on disk has its speakers right."
        }
        var reasons: [String] = []
        if repairCollapsed > 0 {
            reasons.append("\(repairCollapsed) \(repairCollapsed == 1 ? "was" : "were") transcribed before speakers were told apart, so everyone but you shows as \"Speaker\"")
        }
        if repairOverSplit > 0 {
            reasons.append("\(repairOverSplit) \(repairOverSplit == 1 ? "shows" : "show") more voices than were probably on the call — a one-word \"Yeah\" used to become its own speaker")
        }
        return "\(repairable.count) meeting\(repairable.count == 1 ? "" : "s") need\(repairable.count == 1 ? "s" : "") it: \(reasons.joined(separator: "; ")). This listens to the audio again and fixes who each line is attributed to — the words and timings don't change, and a meeting is only changed if listening again hears fewer voices. It doesn't re-transcribe, so it's far quicker than re-processing."
    }

    var body: some View {
        Form {
            Section {
                Picker("Input Device", selection: $audioManager.selectedInputDevice) {
                    ForEach(audioManager.availableInputDevices) { device in
                        Text(device.name).tag(device as AudioSessionManager.AudioDevice?)
                    }
                }

                HStack {
                    Text("Input Gain")
                    Slider(value: $inputGain, in: 0.25...4.0)
                    Text(String(format: "%.1fx", inputGain))
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .frame(width: 36)
                }

                // Isolated subview: `monitor.level` updates on every audio
                // buffer, and reading it in THIS body re-rendered the whole
                // form dozens of times a second — rebuilding the Input Device
                // picker's menu items while the menu was open and wedging the
                // app in an orphaned menu-tracking loop.
                MicLevelMeter(monitor: monitor)
            } header: {
                Label("Microphone", systemImage: "mic")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                Toggle(isOn: $captureSystemAudio) {
                    VStack(alignment: .leading) {
                        Text("Capture system audio (speaker output)")
                        Text("Requires Screen Recording permission")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if captureSystemAudio {
                    Text("System audio will be captured and transcribed as \"Other\" speaker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("System Audio", systemImage: "speaker.wave.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                Toggle("Re-transcribe meetings after recording", isOn: $autoReprocessMeetings)
                Text("Live transcription uses a fast model (FluidAudio Parakeet). When a meeting ends, the audio is re-transcribed in the background with WhisperKit large-v3, and AI insights + embeddings are rebuilt on the upgraded transcript. Re-processing pauses automatically while another recording is in progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("First run downloads the large-v3 model (~1.5 GB).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } header: {
                Label("High-accuracy re-transcription", systemImage: "waveform.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                HStack {
                    Button(isRepairing ? "Listening…" : "Fix speakers in older meetings") {
                        Task { await repairSpeakers() }
                    }
                    .disabled(isRepairing || isScanning || repairable.isEmpty)
                    if isScanning {
                        ProgressView().controlSize(.small)
                        Text("Checking which meetings need it…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isRepairing, repairTotal > 0 {
                        ProgressView(value: Double(repairDone), total: Double(repairTotal))
                            .frame(width: 120)
                        Text("\(repairDone)/\(repairTotal)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if repairResettable > 0 {
                    HStack {
                        Button("Undo speaker fixes") {
                            Task { await resetSpeakers() }
                        }
                        .disabled(isRepairing)
                        Text("Restores the labels \(repairResettable) meeting\(repairResettable == 1 ? "" : "s") had before. Lines you renamed yourself are left as they are.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let repairSummary {
                    Text(repairSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(repairDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Meetings whose audio has already been cleared by the retention setting can't be repaired. Voices are numbered per meeting — \"Speaker 1\" in one isn't the same person as in another.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Label("Speaker separation", systemImage: "person.2.wave.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                LabeledContent("Audio Format") {
                    Text("AAC (.m4a)")
                }
                LabeledContent("Transcription Input") {
                    Text("16kHz mono Float32")
                }
                LabeledContent("Storage Location") {
                    Text("~/Library/Application Support/GreyEminence/Recordings")
                        .font(.caption)
                        .fontDesign(.monospaced)
                }
            } header: {
                Label("Recording Format", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
        .task { await refreshRepairCounts() }
        .task {
            await audioManager.checkMicPermission()
            audioManager.enumerateInputDevices()
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
        .onChange(of: audioManager.selectedInputDevice) { _, newDevice in
            guard let newDevice else { return }
            monitor.startMonitoring(deviceUID: newDevice.uid)
        }
        .onChange(of: inputGain, initial: true) { _, newGain in
            monitor.gain = Float(newGain)
        }
    }
}

/// Level bars in their own view so the per-buffer `level` updates only
/// invalidate this subtree — never the surrounding form and its picker.
private struct MicLevelMeter: View {
    let monitor: MicLevelMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text("Level")
                    .font(.caption)
                ForEach(0..<20, id: \.self) { i in
                    Rectangle()
                        .fill(i < 14 ? .green : (i < 17 ? .yellow : .red))
                        .frame(width: 8, height: 12)
                        .opacity(Double(i) / 20.0 < Double(monitor.level) ? 1.0 : 0.2)
                }
                Text(String(format: "%.3f", monitor.level))
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
            .opacity(monitor.statusMessage == nil ? 1 : 0.4)

            if let status = monitor.statusMessage {
                Label(status, systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

import Foundation
import FluidAudio

@Observable
@MainActor
final class ModelDownloadManager {
    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double, label: String)
        case completed
        case failed(String)
    }

    var diarizationState: DownloadState = .idle
    var whisperState: DownloadState = .idle

    var overallProgress: Double {
        let diarProgress = switch diarizationState {
        case .idle: 0.0
        case .downloading(let p, _): p
        case .completed: 1.0
        case .failed: 0.0
        }
        let whisperProgress = switch whisperState {
        case .idle: 0.0
        case .downloading(let p, _): p
        case .completed: 1.0
        case .failed: 0.0
        }
        return (diarProgress + whisperProgress) / 2.0
    }

    var isComplete: Bool {
        diarizationState == .completed && whisperState == .completed
    }

    var hasError: Bool {
        if case .failed = diarizationState { return true }
        if case .failed = whisperState { return true }
        return false
    }

    // MARK: - Diarization Models

    func downloadDiarizationModels() async {
        diarizationState = .downloading(progress: 0.0, label: "Downloading speaker diarization models...")
        do {
            // FluidAudio downloads models from HuggingFace on first use
            // Models are cached to ~/Library/Application Support/FluidAudio/Models/
            diarizationState = .downloading(progress: 0.3, label: "Downloading segmentation model...")
            let _ = try await DiarizerModels.downloadIfNeeded(to: nil, configuration: nil)
            diarizationState = .downloading(progress: 1.0, label: "Diarization models ready")
            diarizationState = .completed
        } catch {
            diarizationState = .failed(error.localizedDescription)
        }
    }

    // MARK: - WhisperKit Models

    func downloadWhisperModels() async {
        whisperState = .downloading(progress: 0.0, label: "Downloading WhisperKit model...")
        do {
            // WhisperKit model download will be implemented in Phase 3
            // For now, simulate the download
            whisperState = .downloading(progress: 0.5, label: "Downloading distil-large-v3...")
            try await Task.sleep(for: .seconds(1))
            whisperState = .downloading(progress: 1.0, label: "WhisperKit model ready")
            whisperState = .completed
        } catch {
            whisperState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Download All

    func downloadAllModels() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.downloadDiarizationModels() }
            group.addTask { await self.downloadWhisperModels() }
        }
    }
}

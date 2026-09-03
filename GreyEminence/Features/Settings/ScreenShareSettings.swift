import Foundation

/// UserDefaults keys + defaults for screen-share capture. Namespace type,
/// same pattern as `PhaseAlertSettings`.
enum ScreenShareSettings {
    /// Master switch. Off by default — first capture triggers the macOS
    /// Screen Recording permission prompt, so this is a deliberate opt-in.
    static let enabledKey = "screenShareCaptureEnabled"
    static let intervalSecondsKey = "screenShareCaptureInterval"
    static let autoDetectKey = "screenShareAutoDetectWindow"
    static let analysisEnabledKey = "screenShareVisionAnalysis"
    static let maxAnalyzedFramesKey = "screenShareMaxAnalyzedFrames"
    static let maxKeptFramesKey = "screenShareMaxKeptFrames"
    /// dHash Hamming-distance keep threshold (developer setting).
    static let changeThresholdKey = "screenShareChangeThreshold"
    /// Model for per-frame vision analysis. Empty string means "same as
    /// the main model".
    static let frameAnalysisModelKey = "screenShareFrameAnalysisModel"
    /// Pixel budget for the vision payload (developer setting). Disk keeps
    /// the full capture; only the copy sent to the API is downscaled.
    static let analysisPixelBudgetKey = "screenShareAnalysisPixelBudget"

    static let defaultIntervalSeconds = 15.0
    static let defaultMaxAnalyzedFrames = 200
    static let defaultMaxKeptFrames = 400
    static let defaultChangeThreshold = 8
    static let defaultFrameAnalysisModel = AIModelCatalog.haiku
    static let defaultAnalysisPixelBudget = 600_000

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var autoDetect: Bool {
        UserDefaults.standard.object(forKey: autoDetectKey) as? Bool ?? true
    }

    static var analysisEnabled: Bool {
        UserDefaults.standard.object(forKey: analysisEnabledKey) as? Bool ?? true
    }

    static var intervalSeconds: Double {
        let v = UserDefaults.standard.double(forKey: intervalSecondsKey)
        return v > 0 ? min(max(v, 5), 120) : defaultIntervalSeconds
    }

    static var maxAnalyzedFrames: Int {
        let v = UserDefaults.standard.integer(forKey: maxAnalyzedFramesKey)
        return v > 0 ? v : defaultMaxAnalyzedFrames
    }

    static var maxKeptFrames: Int {
        let v = UserDefaults.standard.integer(forKey: maxKeptFramesKey)
        return v > 0 ? v : defaultMaxKeptFrames
    }

    static var changeThreshold: Int {
        let v = UserDefaults.standard.integer(forKey: changeThresholdKey)
        return v > 0 ? min(max(v, 1), 32) : defaultChangeThreshold
    }

    /// Empty string is a deliberate user choice ("same as main model"), so
    /// only a missing key falls back to the Haiku default.
    static var frameAnalysisModel: String {
        AIModelCatalog.canonical(UserDefaults.standard.string(forKey: frameAnalysisModelKey) ?? defaultFrameAnalysisModel)
    }

    static var analysisPixelBudget: Int {
        let v = UserDefaults.standard.integer(forKey: analysisPixelBudgetKey)
        return v > 0 ? min(max(v, 100_000), 4_000_000) : defaultAnalysisPixelBudget
    }
}

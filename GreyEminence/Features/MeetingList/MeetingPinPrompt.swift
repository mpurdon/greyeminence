import Foundation

/// The one-time nudge that introduces pinning: after the first recording
/// completed on a build that has it, ask whether to pin that meeting. Either
/// answer marks the feature seen, and pinning from a context menu does too,
/// so it never asks twice. Fresh installs are seeded as seen at first launch
/// — the prompt is for people who updated into the feature.
enum MeetingPinPrompt {
    static let featureID = "pinned-meetings"

    static let title = "Pin this meeting?"
    static let message = "Pinned meetings stay in a section at the top of the list and never age into the archive. You can pin or unpin any meeting from its right-click menu."

    /// Pure so the rule is tested: never for interview recordings (they have
    /// their own list), and only while the feature is unseen.
    static func shouldAsk(isInterview: Bool, hasSeen: Bool) -> Bool {
        !isInterview && !hasSeen
    }
}

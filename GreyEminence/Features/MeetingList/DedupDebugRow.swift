import SwiftUI

struct DedupDebugRow: View {
    let mic: TranscriptSegment
    let systemSegments: [TranscriptSegment]

    private var info: TranscriptDeduplicator.MatchDebugInfo? {
        TranscriptDeduplicator.debugMatch(mic: mic, sortedSystemSegments: systemSegments)
    }

    var body: some View {
        if let info {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    scoreTag(
                        label: "gap",
                        value: String(format: "%.1fs", info.midpointGap),
                        pass: info.midpointGap <= TranscriptDeduplicator.maxMidpointGap
                    )
                    scoreTag(
                        label: "delay",
                        value: String(format: "%+.1fs", info.echoDelay),
                        pass: info.echoDelay >= -TranscriptDeduplicator.maxLeadTime && info.echoDelay <= TranscriptDeduplicator.maxEchoDelay
                    )
                    scoreTag(
                        label: "similarity",
                        value: String(format: "%.2f", info.textSimilarity),
                        pass: info.textSimilarity >= TranscriptDeduplicator.textSimilarityThreshold
                    )
                    if info.wouldRemove {
                        Text("DUPLICATE")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text("Best match: \"\(info.systemText.prefix(80))\"")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 56)
            .padding(.bottom, 4)
        } else {
            Text("No system segments in range")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 56)
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func scoreTag(label: String, value: String, pass: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: pass ? "checkmark" : "xmark")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(pass ? .green : .red)
            Text("\(label): \(value)")
                .font(.caption2)
                .fontDesign(.monospaced)
                .foregroundStyle(pass ? Color.primary : Color.red)
        }
    }
}

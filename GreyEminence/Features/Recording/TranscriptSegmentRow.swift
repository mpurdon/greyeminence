import SwiftUI

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    var confidence: Float?
    var onLinkSpeaker: ((Speaker) -> Void)?

    @State private var showContactPicker = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Confidence dot (only shown for live segments with low confidence)
            if let conf = confidence, conf < 0.6 {
                Circle()
                    .fill(conf < 0.3 ? Color.red : Color.yellow)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                    .help(String(format: "Confidence: %.0f%%", conf * 100))
            }

            // Timestamp
            Text(segment.formattedTimestamp)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)

            // Speaker badge with context menu for linking
            SpeakerBadge(speaker: segment.speaker)
                .contextMenu {
                    if onLinkSpeaker != nil {
                        Button("Link to Contact...") {
                            showContactPicker = true
                        }
                    }
                }
                .popover(isPresented: $showContactPicker) {
                    ContactPicker(excludedContacts: []) { contact in
                        onLinkSpeaker?(segment.speaker)
                        showContactPicker = false
                    }
                }

            // Edited indicator
            if segment.isEdited {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Edited")
            }

            // Text
            Text(segment.text)
                .font(.body)
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .italic(!segment.isFinal)
                .textSelection(.enabled)
                .opacity(confidenceOpacity)

            Spacer()
        }
        .padding(.vertical, 4)
        .opacity(segment.isFinal ? 1.0 : 0.7)
    }

    private var confidenceOpacity: Double {
        guard let conf = confidence else { return 1.0 }
        if conf >= 0.6 { return 1.0 }
        if conf >= 0.3 { return 0.8 }
        return 0.6
    }
}

struct SpeakerBadge: View {
    let speaker: Speaker

    var body: some View {
        Text(speaker.displayName)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.15), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        speaker.color
    }
}

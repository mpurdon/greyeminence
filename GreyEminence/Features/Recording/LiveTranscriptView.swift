import SwiftUI

struct LiveTranscriptView: View {
    let segments: [TranscriptSegment]
    var segmentConfidence: [UUID: Float] = [:]
    @Binding var scrollToSegmentID: UUID?
    @State private var highlightedSegmentID: UUID?

    init(segments: [TranscriptSegment], segmentConfidence: [UUID: Float] = [:], scrollToSegmentID: Binding<UUID?> = .constant(nil)) {
        self.segments = segments
        self.segmentConfidence = segmentConfidence
        self._scrollToSegmentID = scrollToSegmentID
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(segments) { segment in
                        TranscriptSegmentRow(
                            segment: segment,
                            confidence: segmentConfidence[segment.id]
                        )
                        .id(segment.id)
                        .background(
                            highlightedSegmentID == segment.id
                                ? Color.cyan.opacity(0.15)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding()
            }
            .onChange(of: segments.count) { _, _ in
                if let lastID = segments.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: scrollToSegmentID) { _, newID in
                guard let targetID = newID else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
                highlightedSegmentID = targetID
                scrollToSegmentID = nil
                // Clear highlight after a short delay
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.easeOut(duration: 0.5)) {
                        if highlightedSegmentID == targetID {
                            highlightedSegmentID = nil
                        }
                    }
                }
            }
        }
    }
}

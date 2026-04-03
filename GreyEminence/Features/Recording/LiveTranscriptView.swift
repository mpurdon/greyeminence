import SwiftUI

struct LiveTranscriptView: View {
    let segments: [TranscriptSegment]
    var segmentConfidence: [UUID: Float] = [:]
    @Binding var scrollToSegmentID: UUID?
    @State private var highlightedSegmentID: UUID?
    @State private var highlightTask: Task<Void, Never>?

    init(segments: [TranscriptSegment], segmentConfidence: [UUID: Float] = [:], scrollToSegmentID: Binding<UUID?> = .constant(nil)) {
        self.segments = segments
        self.segmentConfidence = segmentConfidence
        self._scrollToSegmentID = scrollToSegmentID
    }

    private var markerSegmentIDs: [UUID: String] {
        var result: [UUID: String] = [:]
        var lastTag: String?
        for segment in segments {
            if let tag = segment.sectionTag, tag != lastTag {
                result[segment.id] = tag
            }
            lastTag = segment.sectionTag
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let markers = markerSegmentIDs
                    ForEach(segments) { segment in
                        if let markerTitle = markers[segment.id] {
                            SectionMarkerView(
                                title: markerTitle,
                                timestamp: segment.formattedTimestamp
                            )
                        }
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
                highlightTask?.cancel()
                highlightTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
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

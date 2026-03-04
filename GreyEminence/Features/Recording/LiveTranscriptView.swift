import SwiftUI

struct LiveTranscriptView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(segments) { segment in
                        TranscriptSegmentRow(segment: segment)
                            .id(segment.id)
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
        }
    }
}

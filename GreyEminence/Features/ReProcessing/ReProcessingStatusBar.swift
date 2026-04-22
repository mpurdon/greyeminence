import SwiftUI

/// Xcode-style activity bar anchored at the bottom of the main window.
/// Visible only when the re-processing queue has work or just finished some.
struct ReProcessingStatusBar: View {
    @Bindable var queue: ReProcessingQueue = .shared

    @State private var isHovering = false

    private var isActive: Bool {
        queue.current != nil || !queue.pending.isEmpty
    }

    private var recentlyCompleted: Bool {
        queue.lastCompleted != nil
    }

    var body: some View {
        if isActive || recentlyCompleted {
            HStack(spacing: 10) {
                statusIcon
                    .frame(width: 16, height: 16)

                textStack

                Spacer(minLength: 8)

                if queue.pending.count > 0 {
                    StatusPill(label: "+\(queue.pending.count) queued", tint: .secondary)
                }

                if isActive && isHovering {
                    Button {
                        queue.cancelAll()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel all queued re-transcriptions")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(alignment: .top) {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 0.5)
            }
            .background(.bar)
            .onHover { isHovering = $0 }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: 0.24), value: isActive)
            .animation(.easeOut(duration: 0.24), value: recentlyCompleted)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let fraction = queue.current?.progressFraction {
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
        } else if isActive {
            ProgressView().controlSize(.small)
        } else if recentlyCompleted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var textStack: some View {
        if let job = queue.current {
            HStack(spacing: 6) {
                Text(job.title.isEmpty ? "Preparing…" : job.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detailText(for: job))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
        } else if !queue.pending.isEmpty {
            Text("Waiting for live recording to finish")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else if let done = queue.lastCompleted {
            HStack(spacing: 6) {
                Text("Upgraded")
                    .font(.caption.weight(.medium))
                Text(done.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func detailText(for job: ReProcessingQueue.RunningJob) -> String {
        if job.phase == .transcribing, job.chunksTotal > 0 {
            let pct = Int((job.progressFraction ?? 0) * 100)
            return "\(job.phase.stepDescription) — \(job.chunksDone)/\(job.chunksTotal) chunks (\(pct)%)"
        }
        return job.phase.stepDescription
    }
}

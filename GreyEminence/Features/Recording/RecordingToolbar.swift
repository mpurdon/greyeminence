import SwiftUI
import SwiftData

struct RecordingToolbar: View {
    @Bindable var viewModel: RecordingViewModel
    let modelContext: ModelContext

    var body: some View {
        HStack(spacing: 16) {
            // Recording indicator
            HStack(spacing: 8) {
                if viewModel.isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .modifier(PulsingModifier())
                    Text("REC")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.red)
                } else if viewModel.isPaused {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.orange)
                    Text("PAUSED")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 70, alignment: .leading)

            // Timer
            Text(viewModel.formattedTime)
                .font(.system(.title2, design: .monospaced, weight: .medium))
                .foregroundStyle(viewModel.isRecording ? .primary : .secondary)

            Spacer()

            // Controls
            HStack(spacing: 12) {
                if viewModel.state == .idle {
                    Button {
                        viewModel.startRecording(in: modelContext)
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    // Pause/Resume
                    Button {
                        if viewModel.isPaused {
                            viewModel.resumeRecording()
                        } else {
                            viewModel.pauseRecording()
                        }
                    } label: {
                        Label(
                            viewModel.isPaused ? "Resume" : "Pause",
                            systemImage: viewModel.isPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .buttonStyle(.bordered)

                    // Stop
                    Button {
                        viewModel.stopRecording(in: modelContext)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            // Mic level + segment count
            if viewModel.state != .idle {
                Divider()
                    .frame(height: 20)

                // Mic level indicator
                HStack(spacing: 2) {
                    Image(systemName: "mic.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    LevelBar(level: viewModel.micLevel)
                        .frame(width: 40, height: 12)
                }

                // System audio level indicator
                HStack(spacing: 2) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    LevelBar(level: viewModel.systemLevel)
                        .frame(width: 40, height: 12)
                }

                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.segments.count)")
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }

                AIActivityIndicator(state: viewModel.aiActivityState)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(error)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.1), in: Capsule())
                .offset(y: 16)
            }
        }
    }
}

struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > 0.8 ? .red : (level > 0.5 ? .yellow : .green))
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}

struct AIActivityIndicator: View {
    let state: RecordingViewModel.AIActivityState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .waiting(let secs):
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption2)
                Text("AI in \(secs)s")
                    .font(.caption)
                    .fontDesign(.monospaced)
            }
            .foregroundStyle(.secondary)
        case .analyzing:
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption2)
                ProgressView()
                    .controlSize(.mini)
                Text("Analyzing...")
                    .font(.caption)
            }
            .foregroundStyle(.purple)
        }
    }
}

struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

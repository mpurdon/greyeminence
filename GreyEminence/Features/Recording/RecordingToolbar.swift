import SwiftUI
import SwiftData
import EventKit

struct RecordingToolbar: View {
    @Bindable var viewModel: RecordingViewModel
    let modelContext: ModelContext

    var body: some View {
        HStack(spacing: 10) {
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

            // Timer — fixed to one line so a narrow pane never wraps it to "01:" / "45".
            Text(viewModel.formattedTime)
                .font(.system(.title2, design: .monospaced, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(viewModel.isRecording ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()

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

            // Calendar match menu — visible while recording so the user can
            // override an incorrect auto-match or supply one the auto-detector
            // missed (e.g., ad-hoc Teams meeting joined late).
            if viewModel.state != .idle {
                CalendarMatchMenu(viewModel: viewModel, modelContext: modelContext)
                if let prep = viewModel.prepContext, prep.shouldDisplay {
                    PrepButton(context: prep, modelContext: modelContext)
                }
            }

            // Live status cluster (audio levels, segment count, AI activity).
            // Collapses progressively when the pane is too narrow to fit it all,
            // so the timer and primary controls are never crushed into a wrap.
            if viewModel.state != .idle {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        audioMeters
                        segmentCount
                        ScreenCaptureIndicator(viewModel: viewModel)
                        AIActivityIndicator(state: viewModel.aiActivityState)
                    }
                    HStack(spacing: 10) {
                        segmentCount
                        ScreenCaptureIndicator(viewModel: viewModel)
                        AIActivityIndicator(state: viewModel.aiActivityState)
                    }
                    HStack(spacing: 10) {
                        ScreenCaptureIndicator(viewModel: viewModel)
                        AIActivityIndicator(state: viewModel.aiActivityState)
                    }
                    AIActivityIndicator(state: viewModel.aiActivityState)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                Button {
                    viewModel.errorMessage = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text(error)
                            .font(.caption2)
                            .lineLimit(1)
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.6))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .offset(y: 16)
            }
        }
    }

    /// Mic + system-audio level meters, separated from the controls by a rule.
    /// First thing dropped when the toolbar runs out of horizontal room.
    private var audioMeters: some View {
        HStack(spacing: 10) {
            Divider().frame(height: 20)
            HStack(spacing: 2) {
                Image(systemName: "mic.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                LevelBar(level: viewModel.micLevel)
            }
            HStack(spacing: 2) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                LevelBar(level: viewModel.systemLevel)
            }
        }
        .fixedSize()
    }

    private var segmentCount: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.bubble")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(viewModel.segments.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Toolbar control that both shows whether the recording is linked to a
/// calendar event and lets the user change or remove that link. Lists events
/// within ±60 min of now; on selection, applies title, attendees, and
/// recurring-series linkage to the current meeting.
private struct CalendarMatchMenu: View {
    @Bindable var viewModel: RecordingViewModel
    let modelContext: ModelContext
    @State private var nearbyEvents: [CalendarEvent] = []

    private var matchedEventID: String? {
        viewModel.currentMeeting?.calendarEventID
    }

    /// Title of the linked event, or `nil` when the recording isn't linked.
    private var linkedTitle: String? {
        guard let meeting = viewModel.currentMeeting, meeting.isLinkedToCalendar else { return nil }
        return meeting.calendarEventTitle ?? meeting.title
    }

    var body: some View {
        Menu {
            Section("Nearby calendar events") {
                if nearbyEvents.isEmpty {
                    Text("No events within ±1 hour")
                        .foregroundStyle(.secondary)
                } else {
                    // `id` is per-occurrence (won't collide for recurring events);
                    // `linkIdentifier` is the series key we persist + match on.
                    ForEach(nearbyEvents) { event in
                        Button {
                            viewModel.matchCalendarEventManually(event, in: modelContext)
                        } label: {
                            let isMatched = event.linkIdentifier == matchedEventID
                            let prefix = isMatched ? "✓ " : ""
                            Text("\(prefix)\(event.title ?? "Untitled") — \(event.displayTime)")
                        }
                    }
                }
            }
            if linkedTitle != nil {
                Divider()
                UnlinkCalendarButton {
                    viewModel.unlinkCalendarEvent(in: modelContext)
                }
            }
            Divider()
            Button("Refresh") { refresh(force: true) }
        } label: {
            CalendarLinkLabel(linkedTitle: linkedTitle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear { refresh() }
    }

    private func refresh(force: Bool = false) {
        Task { @MainActor in
            if viewModel.calendarService.authorizationState != .authorized {
                await viewModel.calendarService.requestAccess()
            }
            nearbyEvents = await viewModel.calendarService.eventsInWindow(minutes: 60, force: force)
        }
    }
}

/// Compact connection indicator: green with the event title when linked, neutral
/// "Link event" prompt when not.
/// Opens the meeting's prep — what's carried over from past occurrences —
/// over the recording, whether or not the inspector's Prep tab is showing.
private struct PrepButton: View {
    let context: MeetingPrepContext
    let modelContext: ModelContext
    @State private var isShowing = false

    /// Open items and questions: what there is to raise.
    private var openCount: Int {
        context.unresolvedItems.count + context.followUps.count
    }

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                Text("Prep")
                if openCount > 0 {
                    Text("\(openCount)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(openCount > 0 ? "\(openCount) open item(s) and question(s) from past occurrences" : "Meeting prep")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            ScrollView {
                MeetingPrepView(context: context)
                    .padding(16)
                    .frame(width: 440, alignment: .leading)
            }
            .frame(maxHeight: 560)
            // Explicit: prep edits task statuses on the live records.
            .environment(\.modelContext, modelContext)
        }
    }
}

private struct CalendarLinkLabel: View {
    let linkedTitle: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: linkedTitle == nil ? "calendar.badge.plus" : "calendar.badge.checkmark")
            Text(linkedTitle ?? "Link event")
                .lineLimit(1)
                .frame(maxWidth: 160)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption)
        .foregroundStyle(linkedTitle == nil ? Color.secondary : Color.green)
        .help(linkedTitle == nil
              ? "Link this recording to a calendar event"
              : "Linked to \"\(linkedTitle ?? "")\" — click to change or unlink")
    }
}

struct LevelBar: View {
    let level: Float
    var width: CGFloat = 40
    var height: CGFloat = 12

    var body: some View {
        // Intrinsically sized — NO GeometryReader. A bare GeometryReader has
        // no ideal size, so the toolbar's `.fixedSize()` cluster inside a
        // `ViewThatFits` re-measured it combinatorially and beachballed the
        // UI during recording (every new transcript segment retriggered the
        // pass). Computing the fill width from an explicit `width` keeps
        // layout O(1).
        let fill = width * CGFloat(min(max(level, 0), 1))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.secondary.opacity(0.2))
            RoundedRectangle(cornerRadius: 2)
                .fill(level > 0.8 ? .red : (level > 0.5 ? .yellow : .green))
                .frame(width: fill)
                .animation(.linear(duration: 0.1), value: level)
        }
        .frame(width: width, height: height)
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
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
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
            .lineLimit(1)
            .fixedSize()
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

import SwiftUI
import SwiftData
import AppKit

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: RecordingViewModel
    /// When true, the live transcript fills the body. When false, the live
    /// intelligence view fills the body and the transcript is expected to live
    /// in a separate pane (e.g. the inspector).
    var showsTranscript: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            RecordingToolbar(viewModel: viewModel, modelContext: modelContext)

            if viewModel.state != .idle, let meeting = viewModel.currentMeeting {
                Divider()
                MeetingAttendeesRow(meeting: meeting)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                    .onChange(of: meeting.attendees.count) { _, _ in
                        viewModel.speakerContactMapper.prepopulate(from: meeting.presentAttendees)
                    }
            }

            Divider()

            if viewModel.state == .idle {
                idleState
            } else if showsTranscript {
                LiveTranscriptView(
                    segments: viewModel.segments,
                    segmentConfidence: viewModel.segmentConfidence
                )
            } else {
                LiveMeetingIntelligenceView(
                    summary: viewModel.streamingSummary,
                    actionItems: viewModel.actionItems,
                    followUpQuestions: viewModel.followUpQuestions,
                    topics: viewModel.topics,
                    aiActivityState: viewModel.aiActivityState,
                    shareObservations: viewModel.screenObservationLog,
                    isCapturingShare: {
                        if case .capturing = viewModel.screenCaptureState { true } else { false }
                    }(),
                    meeting: viewModel.currentMeeting
                )
            }

            if viewModel.state != .idle {
                Divider()
                NoteInputBar(viewModel: viewModel)
            }
        }
        .navigationTitle(viewModel.currentMeeting?.title ?? "New Recording")
        .task {
            await TranscriptionCoordinator.preloadModels()
        }
        // NOTE: the calendar-event picker sheet is presented at the ContentView
        // root, not here — a recording can be started from the menu bar or the
        // auto-detector while this view isn't mounted, and the picker must still
        // appear.
    }

    private var idleState: some View {
        VStack(spacing: 20) {
            Spacer()

            // Which calendar meeting are we about to record? Drives prep + link.
            calendarSelector

            // Meeting prep view
            if let prepContext = viewModel.prepContext, prepContext.shouldDisplay {
                MeetingPrepView(context: prepContext)
                    .frame(maxWidth: 500)
            }

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Ready to Record")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Click the record button to start capturing your meeting")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                viewModel.startRecording(in: modelContext)
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut("r", modifiers: .command)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .task {
            await viewModel.refreshCalendarCandidates(in: modelContext)
        }
    }

    /// Idle-screen control for choosing which calendar meeting this recording
    /// belongs to. The selection drives both the prep card and the record-start
    /// link, so we never guess silently or ask twice. Hidden when there are no
    /// nearby events.
    @ViewBuilder
    private var calendarSelector: some View {
        if let selected = viewModel.selectedEvent {
            // Confirmed selection — show it; allow changing or clearing.
            Menu {
                ForEach(viewModel.candidateEvents) { event in
                    Button {
                        viewModel.selectEvent(event, in: modelContext)
                    } label: {
                        Label(eventLabel(event),
                              systemImage: event.id == selected.id ? "checkmark" : "calendar")
                    }
                }
                Divider()
                Button("Not a calendar meeting") { viewModel.clearSelectedEvent() }
            } label: {
                calendarChip(for: selected, showsChevron: viewModel.candidateEvents.count > 1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else if viewModel.calendarSelectionCleared {
            Button {
                viewModel.reopenCalendarSelection(in: modelContext)
            } label: {
                Label("Link a calendar event", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if viewModel.candidateEvents.count >= 2 {
            // Conflict: make the choice explicit — no prep until one is picked.
            VStack(alignment: .leading, spacing: 8) {
                Text("Which meeting are you recording?")
                    .font(.subheadline.weight(.semibold))
                ForEach(viewModel.candidateEvents) { event in
                    Button {
                        viewModel.selectEvent(event, in: modelContext)
                    } label: {
                        HStack(spacing: 10) {
                            eventRow(event, titleFont: .body)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Not a calendar meeting") { viewModel.clearSelectedEvent() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 500)
        }
        // 0 candidates → nothing.
    }

    private func calendarChip(for event: CalendarEvent, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            eventRow(event, titleFont: .headline)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Calendar icon + title + start time — the shared visual unit for every
    /// event row (the selected chip and the conflict-list buttons).
    private func eventRow(_ event: CalendarEvent, titleFont: Font) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Meeting").font(titleFont)
                Text(event.displayTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func eventLabel(_ event: CalendarEvent) -> String {
        "\(event.title ?? "Meeting") — \(event.displayTime)"
    }
}

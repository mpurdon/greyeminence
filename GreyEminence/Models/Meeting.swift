import Foundation
import SwiftData

enum MeetingStatus: String, Codable, Sendable {
    case recording
    case paused
    case completed
}

@Model
final class Meeting {
    var id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var status: MeetingStatus
    var audioFilePath: String?
    var systemAudioFilePath: String?
    var isExportedToObsidian: Bool
    var isAnalyzing: Bool = false
    var analysisError: String?
    var isInterviewMeeting: Bool = false
    var createdAt: Date

    /// Identifier of the transcription backend used to produce the current
    /// segments. `nil` on legacy meetings; "fluidaudio-parakeet-v2" for live
    /// transcriptions; "whisperkit-large-v3" once re-transcribed offline.
    var transcriptionModel: String?

    /// In-flight re-processing state. `nil` when not queued. One of:
    /// "queued" | "transcribing" | "analyzing" | "reindexing" | "failed"
    var reProcessingState: String?
    var reProcessingError: String?

    /// When a meeting is split, the new half doesn't copy the audio files —
    /// instead it points back at the original meeting and records which slice
    /// of that audio timeline belongs to it. Re-transcription uses these to
    /// read the right chunks from the right meeting's folder.
    /// `nil` means this meeting owns its own audio (the normal case).
    var audioSourceMeetingID: UUID?
    var audioStartOffset: TimeInterval = 0
    /// `nil` = "runs to the end of the source audio".
    var audioEndOffset: TimeInterval?

    /// Normalized keys of action items the user has explicitly deleted.
    /// The AI is instructed not to re-suggest these during reanalysis, and
    /// any that slip through are filtered out post-parse.
    var suppressedActionItems: [String] = []

    /// Follow-up questions the user has explicitly deleted — same semantics
    /// as suppressedActionItems but stored as normalized question text.
    var suppressedFollowUps: [String] = []

    /// The app the call was held in, when we can tell — bundle ID plus a
    /// friendly name. Recorded from whichever process held the microphone at
    /// the moment recording started, falling back to the app that owned the
    /// captured screen-share window. `nil` on legacy meetings and whenever
    /// nothing else had the mic (a dictation-style solo recording).
    var sourceAppBundleID: String?
    var sourceAppName: String?

    // Calendar integration
    var calendarEventID: String?
    var calendarEventTitle: String?

    /// Title produced by the AI analysis, kept separately from `title` so that
    /// when a meeting is linked to a calendar event (and `title` shows the event
    /// name) we can still restore the auto-generated name if the user later
    /// unlinks the event. `nil` until the first analysis pass returns a title.
    var generatedTitle: String?

    // Recurring meeting tracking
    var seriesID: UUID?
    var seriesTitle: String?

    /// True when this meeting is currently associated with a calendar event.
    var isLinkedToCalendar: Bool { calendarEventID != nil }

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment]

    @Relationship(deleteRule: .cascade, inverse: \ActionItem.meeting)
    var actionItems: [ActionItem]

    @Relationship(deleteRule: .cascade, inverse: \MeetingInsight.meeting)
    var insights: [MeetingInsight]

    @Relationship(deleteRule: .cascade, inverse: \ScreenShareFrame.meeting)
    var screenFrames: [ScreenShareFrame] = []

    @Relationship(deleteRule: .cascade, inverse: \ShareSessionSummary.meeting)
    var sessionSummaries: [ShareSessionSummary] = []

    @Relationship(deleteRule: .nullify)
    var attendees: [Contact] = []

    /// Invitees who were not in the room. They stay in `attendees` so the
    /// invite is still visible, and drop out of `presentAttendees`, which is
    /// what the AI roster, the voice matcher and task assignment work from.
    /// IDs rather than a second relationship: no join table, and a contact
    /// removed from the meeting simply stops matching.
    var absentAttendeeIDs: [UUID] = []

    /// Everyone who was actually there.
    var presentAttendees: [Contact] {
        guard !absentAttendeeIDs.isEmpty else { return attendees }
        let absent = Set(absentAttendeeIDs)
        return attendees.filter { !absent.contains($0.id) }
    }

    func isAbsent(_ contact: Contact) -> Bool {
        absentAttendeeIDs.contains(contact.id)
    }

    func setAbsent(_ contact: Contact, _ absent: Bool) {
        if absent {
            if !absentAttendeeIDs.contains(contact.id) { absentAttendeeIDs.append(contact.id) }
        } else {
            absentAttendeeIDs.removeAll { $0 == contact.id }
        }
    }

    init(
        title: String = "New Meeting",
        date: Date = .now,
        duration: TimeInterval = 0,
        status: MeetingStatus = .recording
    ) {
        self.id = UUID()
        self.title = title
        self.date = date
        self.duration = duration
        self.status = status
        self.isExportedToObsidian = false
        self.isAnalyzing = false
        self.createdAt = .now
        self.segments = []
        self.actionItems = []
        self.insights = []
        self.attendees = []
    }

    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var pendingActionCount: Int {
        actionItems.count(where: { !$0.isCompleted })
    }

    var latestInsight: MeetingInsight? {
        insights.max(by: { $0.createdAt < $1.createdAt })
    }

    /// Record an AI-generated title. Always stored in `generatedTitle`; only
    /// promoted to the visible `title` when the meeting isn't linked to a
    /// calendar event (a linked meeting keeps the event's name).
    func applyGeneratedTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        generatedTitle = trimmed
        if !isLinkedToCalendar {
            title = trimmed
        }
    }

    /// Cancel the association with a calendar event. If the title is still the
    /// event-derived name, restore the auto-generated title so the recording
    /// stops showing the (now-irrelevant) event name. But if the user manually
    /// renamed the meeting (title no longer matches the event title), keep their
    /// name — don't clobber a deliberate edit.
    ///
    /// Attendees are pruned to just "me": unlinking means the event was the
    /// wrong one, so the attendees it contributed are presumed wrong too. With
    /// no My Profile configured, everyone is removed.
    func unlinkCalendarEvent(keepingAttendeeID myID: UUID? = Meeting.storedMyContactID) {
        let titleIsEventDerived = (title == calendarEventTitle)
        calendarEventID = nil
        calendarEventTitle = nil
        seriesID = nil
        seriesTitle = nil
        if titleIsEventDerived,
           let generated = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !generated.isEmpty {
            title = generated
        }
        attendees.removeAll { $0.id != myID }
    }

    /// The user's own Contact id from Settings → My Profile (same key
    /// `@AppStorage("myContactID")` writes). `nil` when not configured.
    static var storedMyContactID: UUID? {
        UUID(uuidString: UserDefaults.standard.string(forKey: "myContactID") ?? "")
    }
}

extension Array where Element == TranscriptSegment {
    /// Best segment match for an AI-supplied verbatim quote. Substring
    /// containment wins; otherwise falls back to ≥3 shared meaningful tokens.
    func segmentID(matchingQuote rawQuote: String?) -> UUID? {
        guard let raw = rawQuote?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count >= 8 else { return nil }
        let needle = raw.lowercased()
        let needleTokens = Set(needle.split(separator: " ").map(String.init).filter { $0.count >= 3 })

        var bestID: UUID? = nil
        var bestScore = 0
        for segment in self {
            let hay = segment.text.lowercased()
            if hay.contains(needle) || (needle.count >= hay.count && needle.contains(hay)) {
                return segment.id
            }
            let hayTokens = Set(hay.split(separator: " ").map(String.init).filter { $0.count >= 3 })
            let overlap = needleTokens.intersection(hayTokens).count
            if overlap > bestScore {
                bestScore = overlap
                bestID = segment.id
            }
        }
        return bestScore >= 3 ? bestID : nil
    }

    /// Segments around the one with `id`, sorted by start time. Returns up to
    /// `lead` segments before and `trail` after, clamped to array bounds.
    /// Empty when `id` isn't found.
    func segments(around id: UUID, lead: Int, trail: Int) -> [TranscriptSegment] {
        let sorted = self.sorted { $0.startTime < $1.startTime }
        guard let idx = sorted.firstIndex(where: { $0.id == id }) else { return [] }
        let lo = Swift.max(0, idx - lead)
        let hi = Swift.min(sorted.count - 1, idx + trail)
        return Array(sorted[lo...hi])
    }
}

import Foundation
import SwiftData

/// Naming a diarized speaker, and remembering the voice.
///
/// The two halves are inseparable on purpose: relabelling without enrolling
/// fixes one transcript and teaches nothing, and enrolling without relabelling
/// leaves the meeting you were reading still full of numbers.
@MainActor
enum SpeakerIdentityService {
    /// A voice in one meeting that hasn't been put to a person yet.
    struct Unidentified: Identifiable {
        let label: String
        let seconds: TimeInterval
        let segmentCount: Int
        /// Whose voice this might be, when it resembles someone enrolled.
        let suggestion: VoiceProfileStore.Match?
        /// False when the meeting predates signature capture — it can still be
        /// named by hand, it just can't teach the profile anything.
        let hasSignature: Bool

        var id: String { label }
    }

    /// Labels that mean "we don't know who this is": the collapsed fallback,
    /// and the per-meeting numbering.
    nonisolated static func isUnidentified(_ name: String) -> Bool {
        Speaker.other(name).isUnidentified
    }

    /// Voices in a meeting still awaiting a name, most talkative first.
    static func unidentifiedSpeakers(in meeting: Meeting) -> [Unidentified] {
        var seconds: [String: TimeInterval] = [:]
        var counts: [String: Int] = [:]
        for segment in meeting.segments {
            guard case .other(let name) = segment.speaker, isUnidentified(name) else { continue }
            seconds[name, default: 0] += max(0, segment.endTime - segment.startTime)
            counts[name, default: 0] += 1
        }
        // Most meetings have nothing unidentified. Returning before any disk
        // access keeps opening one free — this runs on the main actor for
        // every meeting selected.
        guard !seconds.isEmpty else { return [] }

        let stored = StorageManager.shared.loadVoiceClusters(for: meeting.id)
        let profiles = VoiceProfileStore.load()
        // Only people in the room are candidates; matching against everyone
        // ever enrolled invites a confident name from another meeting.
        let attendeeIDs = Set(meeting.presentAttendees.map(\.id))

        return seconds.map { label, total in
            let signature = stored?.cluster(labelled: label)?.signature
            return Unidentified(
                label: label,
                seconds: total,
                segmentCount: counts[label] ?? 0,
                suggestion: signature.flatMap {
                    VoiceProfileStore.bestMatch(
                        for: $0,
                        among: attendeeIDs.isEmpty ? nil : attendeeIDs,
                        profiles: profiles
                    )
                },
                hasSignature: signature != nil
            )
        }
        .sorted { $0.seconds > $1.seconds }
    }

    @discardableResult
    static func identify(
        label: String,
        as contact: Contact,
        in meeting: Meeting,
        context: ModelContext
    ) -> Int {
        var relabelled = 0
        for segment in meeting.segments {
            guard case .other(let name) = segment.speaker, name == label else { continue }
            // Same stash the repair uses, so an identification can be undone
            // the same way — and without claiming to be a manual edit.
            if !segment.isEdited, segment.originalSpeakerData == nil {
                segment.originalSpeakerData = segment.speakerData
            }
            segment.speaker = .other(contact.name)
            relabelled += 1
        }
        guard relabelled > 0 else { return 0 }

        // Record the label on the contact as well as the voice. The roster is
        // what the text side reads — Ask resolves people through
        // `speakerAliases`, and so does calendar attendee matching — so
        // teaching only the voice profile would improve recognition while
        // leaving every other consumer none the wiser.
        let lowered = label.lowercased()
        if !contact.speakerAliases.contains(where: { $0.lowercased() == lowered }) {
            contact.speakerAliases.append(label)
        }

        // Teach the profile, if this meeting captured a signature. Meetings
        // diarized before signatures were stored can still be named — they
        // just contribute nothing to recognising the voice next time.
        if let signature = StorageManager.shared.loadVoiceClusters(for: meeting.id)?
            .cluster(labelled: label)?.signature {
            VoiceProfileStore.enroll(signature, contactID: contact.id, contactName: contact.name)
        } else {
            LogManager.send(
                "Named \(label) as \(contact.name), but this meeting has no voice signature — it won't help recognise them elsewhere",
                category: .transcription,
                meetingID: meeting.id
            )
        }

        PersistenceGate.save(
            context,
            site: "SpeakerIdentity.identify",
            critical: false,
            meetingID: meeting.id
        )
        // Indexed snippets carry the speaker name, so they'd keep quoting the
        // number back until re-indexed.
        SpeakerRepairService.invalidateSearchIndex(for: meeting)
        LogManager.send(
            "\(label) is \(contact.name) — \(relabelled) segment(s) in \"\(meeting.title)\"",
            category: .transcription,
            meetingID: meeting.id
        )
        return relabelled
    }
}

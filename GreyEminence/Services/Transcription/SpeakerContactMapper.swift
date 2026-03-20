import Foundation
import SwiftData

@Observable
@MainActor
final class SpeakerContactMapper {
    /// Maps speaker display names to Contact records for the current session.
    private(set) var speakerToContact: [String: Contact] = [:]

    /// Link a speaker label to a contact. Relabels existing segments and adds alias.
    func linkSpeaker(
        _ speakerName: String,
        to contact: Contact,
        in segments: inout [TranscriptSegment]
    ) {
        speakerToContact[speakerName] = contact

        // Add alias if not already present
        let lowered = speakerName.lowercased()
        if !contact.speakerAliases.contains(where: { $0.lowercased() == lowered }) {
            contact.speakerAliases.append(speakerName)
        }

        // Relabel existing segments with matching speaker
        for i in segments.indices {
            if segments[i].speaker.displayName == speakerName {
                segments[i].speaker = .other(contact.name)
            }
        }
    }

    /// Suggest a contact for a speaker name by fuzzy-matching aliases.
    func suggestContact(for speakerName: String, from contacts: [Contact]) -> Contact? {
        let lowered = speakerName.lowercased()

        // Exact alias match
        for contact in contacts {
            if contact.speakerAliases.contains(where: { $0.lowercased() == lowered }) {
                return contact
            }
        }

        // Name contains match
        for contact in contacts {
            if contact.name.lowercased().contains(lowered) || lowered.contains(contact.name.lowercased()) {
                return contact
            }
        }

        return nil
    }

    /// Pre-populate mappings from attendee aliases.
    func prepopulate(from contacts: [Contact]) {
        for contact in contacts {
            for alias in contact.speakerAliases {
                speakerToContact[alias] = contact
            }
        }
    }

    func reset() {
        speakerToContact = [:]
    }
}

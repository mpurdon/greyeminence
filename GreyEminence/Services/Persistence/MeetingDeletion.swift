import Foundation
import SwiftData

/// Deletes a meeting and its audio files, taking split relationships into
/// account. A split meeting references its parent's audio via
/// `audioSourceMeetingID`, so the parent's recording directory must not be
/// removed while any other meeting still points at it.
enum MeetingDeletion {
    static func delete(_ meeting: Meeting, in context: ModelContext, allMeetings: [Meeting]) {
        let meetingID = meeting.id
        let audioSourceID = meeting.audioSourceMeetingID ?? meetingID

        context.delete(meeting)
        PersistenceGate.save(context, site: "MeetingDeletion.delete", meetingID: meetingID)

        let stillReferenced = allMeetings.contains { other in
            guard other.id != meetingID else { return false }
            let otherSource = other.audioSourceMeetingID ?? other.id
            return otherSource == audioSourceID
        }

        if stillReferenced {
            LogManager.send("Deleted meeting \(meetingID); keeping audio for \(audioSourceID) (referenced by another meeting)", category: .general)
            return
        }

        let removed = StorageManager.shared.deleteRecording(for: audioSourceID)
        if removed {
            LogManager.send("Deleted meeting \(meetingID) and audio files", category: .general)
        }
    }
}

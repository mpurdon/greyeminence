import Foundation
import SwiftData

enum MeetingDeletion {
    /// A split meeting references its parent's audio via `audioSourceMeetingID`,
    /// so the parent's recording directory must not be removed while any other
    /// meeting still points at it. Pass `allMeetings` if you already have the
    /// list; otherwise it'll be fetched from `context`.
    static func delete(_ meeting: Meeting, in context: ModelContext, allMeetings: [Meeting]? = nil) {
        let meetingID = meeting.id
        let audioSourceID = meeting.audioSourceMeetingID ?? meetingID
        let others = allMeetings ?? ((try? context.fetch(FetchDescriptor<Meeting>())) ?? [])

        context.delete(meeting)
        PersistenceGate.save(context, site: "MeetingDeletion.delete", meetingID: meetingID)

        let stillReferenced = others.contains { other in
            guard other.id != meetingID else { return false }
            let otherSource = other.audioSourceMeetingID ?? other.id
            return otherSource == audioSourceID
        }

        if stillReferenced {
            LogManager.send("Deleted meeting \(meetingID); keeping audio for \(audioSourceID) (referenced by another meeting)", category: .general)
            return
        }

        if StorageManager.shared.deleteRecording(for: audioSourceID) {
            LogManager.send("Deleted meeting \(meetingID) and audio files", category: .general)
        }
    }
}

import Foundation
import SwiftData

/// Turns Meeting content (transcript, tasks, follow-ups, summary) into
/// embedding records in the dedicated embedding store. Safe to call
/// repeatedly — upserts by composite id.
@MainActor
final class EmbeddingIndexer {
    let store: EmbeddingStore
    let service: EmbeddingService

    init(store: EmbeddingStore, service: EmbeddingService) {
        self.store = store
        self.service = service
    }

    /// Embed everything in a single meeting. Writes one SwiftData save at the end.
    func indexMeeting(_ meeting: Meeting) async {
        guard service.isAvailable else { return }
        let meetingID = meeting.id
        let title = meeting.title
        let date = meeting.date

        for segment in meeting.segments {
            guard let vec = await service.embed(segment.text) else { continue }
            let record = EmbeddingRecord(
                id: "segment:\(segment.id)",
                sourceID: segment.id,
                sourceKind: .transcriptSegment,
                meetingID: meetingID,
                meetingTitle: title,
                meetingDate: date,
                text: segment.text,
                vector: vec,
                modelIdentifier: service.modelIdentifier
            )
            store.upsert(record)
        }

        for item in meeting.actionItems {
            let text = item.assignee.map { "\(item.text) (assigned: \($0))" } ?? item.text
            guard let vec = await service.embed(text) else { continue }
            let record = EmbeddingRecord(
                id: "action:\(item.id)",
                sourceID: item.id,
                sourceKind: .actionItem,
                meetingID: meetingID,
                meetingTitle: title,
                meetingDate: date,
                text: text,
                vector: vec,
                modelIdentifier: service.modelIdentifier
            )
            store.upsert(record)
        }

        for insight in meeting.insights {
            if !insight.summary.isEmpty, let vec = await service.embed(insight.summary) {
                let record = EmbeddingRecord(
                    id: "summary:\(insight.id)",
                    sourceID: insight.id,
                    sourceKind: .meetingSummary,
                    meetingID: meetingID,
                    meetingTitle: title,
                    meetingDate: date,
                    text: insight.summary,
                    vector: vec,
                    modelIdentifier: service.modelIdentifier
                )
                store.upsert(record)
            }
            for (i, question) in insight.followUpQuestions.enumerated() {
                guard let vec = await service.embed(question) else { continue }
                let record = EmbeddingRecord(
                    id: "followup:\(insight.id):\(i)",
                    sourceID: insight.id,
                    sourceKind: .followUpQuestion,
                    meetingID: meetingID,
                    meetingTitle: title,
                    meetingDate: date,
                    text: question,
                    vector: vec,
                    modelIdentifier: service.modelIdentifier
                )
                store.upsert(record)
            }
        }

        store.save()
    }

    /// Full reindex across all meetings in the main store. Call after the user
    /// switches embedding providers or presses "Reindex all".
    func reindexAll(mainContext: ModelContext, onProgress: @MainActor @escaping (Int, Int) -> Void) async {
        store.deleteRecords(matching: service.modelIdentifier)

        let meetings = (try? mainContext.fetch(FetchDescriptor<Meeting>())) ?? []
        let total = meetings.count
        for (i, meeting) in meetings.enumerated() {
            onProgress(i, total)
            await indexMeeting(meeting)
        }
        onProgress(total, total)
    }
}

import Foundation
import SwiftData

struct StalledCommitment: Identifiable {
    let id: UUID
    let actionItem: ActionItem
    let meetingTitle: String
    let meetingDate: Date
    let daysStalled: Int

    var urgency: Urgency {
        if daysStalled > 14 { return .high }
        if daysStalled > 7 { return .medium }
        return .low
    }

    enum Urgency {
        case low, medium, high
    }
}

@MainActor
final class CommitmentTrackingService {
    /// Find incomplete action items from meetings older than a threshold.
    func stalledCommitments(in context: ModelContext, threshold: Int = 7) -> [StalledCommitment] {
        let descriptor = FetchDescriptor<ActionItem>(
            predicate: #Predicate<ActionItem> { !$0.isCompleted }
        )
        guard let items = try? context.fetch(descriptor) else { return [] }

        let now = Date.now
        let calendar = Calendar.current

        return items.compactMap { item in
            let days = calendar.dateComponents([.day], from: item.createdAt, to: now).day ?? 0
            guard days >= threshold else { return nil }
            return StalledCommitment(
                id: item.id,
                actionItem: item,
                meetingTitle: item.meeting?.title ?? "Unknown",
                meetingDate: item.meeting?.date ?? item.createdAt,
                daysStalled: days
            )
        }.sorted { $0.daysStalled > $1.daysStalled }
    }

    /// Find stalled items assigned to a specific contact.
    func stalledCommitments(for contact: Contact, threshold: Int = 7) -> [StalledCommitment] {
        let now = Date.now
        let calendar = Calendar.current

        return contact.assignedActionItems
            .filter { !$0.isCompleted }
            .compactMap { item in
                let days = calendar.dateComponents([.day], from: item.createdAt, to: now).day ?? 0
                guard days >= threshold else { return nil }
                return StalledCommitment(
                    id: item.id,
                    actionItem: item,
                    meetingTitle: item.meeting?.title ?? "Unknown",
                    meetingDate: item.meeting?.date ?? item.createdAt,
                    daysStalled: days
                )
            }
            .sorted { $0.daysStalled > $1.daysStalled }
    }

    /// Completion rate for a contact's action items.
    func completionRate(for contact: Contact) -> Double? {
        let total = contact.assignedActionItems.count
        guard total > 0 else { return nil }
        let completed = contact.assignedActionItems.filter(\.isCompleted).count
        return Double(completed) / Double(total)
    }
}

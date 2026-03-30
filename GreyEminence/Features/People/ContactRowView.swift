import SwiftUI
import SwiftData

struct ContactRowView: View {
    let contact: Contact

    var body: some View {
        HStack(spacing: 10) {
            Text(contact.initials)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(contact.avatarColor.gradient, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(contact.name)
                        .font(.body)
                    if contact.nickname != nil {
                        Text("\u{201C}\(contact.displayNickname)\u{201D}")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let email = contact.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !contact.meetings.isEmpty {
                Text("\(contact.meetings.count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 2)
    }
}

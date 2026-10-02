import SwiftUI

/// A tinted one-line notice with actions — errors, staleness, what to do
/// next. Refinement reports, specs and diagrams all use it.
struct NoticeBanner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: Actions

    init(systemImage: String, tint: Color, text: String, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage
        self.tint = tint
        self.text = text
        self.actions = actions()
    }

    init(_ text: String, systemImage: String, tint: Color, @ViewBuilder actions: () -> Actions) {
        self.init(systemImage: systemImage, tint: tint, text: text, actions: actions)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
                .controlSize(.small)
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// "Working on it" while a long AI call runs.
struct WorkingCard: View {
    let title: String
    let caption: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Progress of a background pass over older meetings, or why it stopped.
struct BackfillBanner: View {
    let isRunning: Bool
    let checked: Int
    let total: Int
    let lastError: String?
    /// "Checking older meetings"
    let activity: String

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                ProgressView().controlSize(.small)
                Text("\(activity)… \(checked) of \(total)")
            } else if let lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't check older meetings: \(lastError)")
                    .lineLimit(2)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

import SwiftUI
import AppKit

struct LogView: View {
    private let logManager = LogManager.shared

    @State private var selectedCategory: LogEntry.Category?
    @State private var selectedLevel: LogEntry.Level?

    private var filteredEntries: [LogEntry] {
        logManager.entries.filter { entry in
            if let cat = selectedCategory, entry.category != cat { return false }
            if let lvl = selectedLevel, entry.level != lvl { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            logList
        }
        .navigationTitle("Activity Log")
        .overlay {
            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No Log Entries",
                    systemImage: "list.bullet.clipboard",
                    description: Text("Activity from recordings and services will appear here")
                )
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Category", selection: $selectedCategory) {
                Text("All Categories").tag(LogEntry.Category?.none)
                Divider()
                ForEach(LogEntry.Category.allCases) { cat in
                    Text(cat.rawValue.capitalized).tag(LogEntry.Category?.some(cat))
                }
            }
            .frame(width: 160)

            Picker("Level", selection: $selectedLevel) {
                Text("All Levels").tag(LogEntry.Level?.none)
                Divider()
                ForEach(LogEntry.Level.allCases) { lvl in
                    Text(lvl.rawValue.capitalized).tag(LogEntry.Level?.some(lvl))
                }
            }
            .frame(width: 130)

            Spacer()

            Button {
                copyToClipboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(filteredEntries.isEmpty)

            Button("Clear", role: .destructive) {
                logManager.clear()
            }
            .disabled(logManager.entries.isEmpty)
        }
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries) { entry in
                logRow(entry)
                    .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: logManager.entries.count) {
                if let last = filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)

                Text(entry.category.rawValue.uppercased())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(categoryColor(entry.category).opacity(0.15), in: Capsule())
                    .foregroundStyle(categoryColor(entry.category))

                Text(entry.message)
                    .font(.callout)
                    .foregroundStyle(levelColor(entry.level))
                    .lineLimit(3)
            }
            .padding(.vertical, 2)

            if let detail = entry.detail {
                DetailDisclosure(detail: detail)
                    .padding(.leading, 80)
                    .padding(.top, 2)
            }
        }
    }

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func copyToClipboard() {
        let text = filteredEntries.map { entry in
            let time = Self.logDateFormatter.string(from: entry.timestamp)
            return "\(time)  [\(entry.category.rawValue.uppercased())]  \(entry.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func categoryColor(_ category: LogEntry.Category) -> Color {
        switch category {
        case .audio: .blue
        case .transcription: .purple
        case .ai: .green
        case .obsidian: .indigo
        case .general: .gray
        }
    }

    private func levelColor(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct DetailDisclosure: View {
    let detail: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(isExpanded ? "Hide payload" : "Show payload")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView([.horizontal, .vertical]) {
                    Text(detail)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 300)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

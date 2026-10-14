import SwiftUI

/// Deliverables as a Gantt chart: names and owners in a column on the
/// left, each on its own row across a real date axis — a bar from start to
/// due, a dot for a due date alone, a diamond for a milestone. Estimated
/// dates — resolved from "next Friday" — are drawn lighter. Times the
/// meeting gave ("3pm IST") place marks within the day, on an hourly axis.
/// The meeting and today are marked; undated items are listed below, to
/// date or ignore.
struct TimelineDiagramView: View {
    let timeline: TimelineDiagram
    let meetingDate: Date
    var selectedItemID: String?
    var onSelect: ((String?) -> Void)?
    /// False in exports: today is a moving line on screen, not on paper.
    var showsToday = true
    /// Give an undated item a due date; nil hides the control (exports).
    var onSetDate: ((String, Date) -> Void)?
    /// Ignore (true) or restore (false) an item; nil hides the controls.
    var onIgnore: ((String, Bool) -> Void)?

    static let labelWidth: CGFloat = 280
    static let rowHeight: CGFloat = 44
    static let axisHeight: CGFloat = 24

    var body: some View {
        let rows = TimelineRows(timeline)
        VStack(alignment: .leading, spacing: 20) {
            if rows.dated.isEmpty {
                Text("The meeting gave no dates to place. What it did say is listed below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                GanttChart(
                    rows: rows,
                    domain: rows.domain(including: meetingDate, today: showsToday ? .now : nil),
                    meetingDate: meetingDate,
                    today: showsToday ? .now : nil,
                    selectedItemID: selectedItemID,
                    onSelect: onSelect
                )
                .frame(height: Self.axisHeight + CGFloat(rows.dated.count) * Self.rowHeight)
            }
            if !timeline.undated.isEmpty {
                undatedList
            }
            if let onIgnore, !timeline.ignored.isEmpty {
                DisclosureGroup("Ignored (\(timeline.ignored.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(timeline.ignored) { item in
                            HStack(spacing: 8) {
                                Text(item.name).foregroundStyle(.secondary)
                                Button("Restore") { onIgnore(item.id, false) }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var undatedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NO DATE GIVEN (\(timeline.undated.count))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(timeline.undated) { item in
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.callout.weight(.medium))
                        let detail = [item.dateText?.nonEmpty.map { "“\($0)”" }, item.owner?.nonEmpty].compactMap { $0 }
                        if !detail.isEmpty {
                            Text(detail.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    if let onSetDate {
                        SetDateButton(meetingDate: meetingDate) { onSetDate(item.id, $0) }
                    }
                    if let onIgnore {
                        Button("Ignore") { onIgnore(item.id, true) }
                            .controlSize(.small)
                            .help("Leave it off the timeline. You can bring it back.")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(item.id == selectedItemID ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { onSelect?(item.id) }
                Divider().opacity(0.5)
            }
        }
    }
}

/// The dated rows: a label column, then a track where x is the date.
struct GanttChart: View {
    let rows: TimelineRows
    let domain: ClosedRange<Date>
    let meetingDate: Date
    let today: Date?
    let selectedItemID: String?
    let onSelect: ((String?) -> Void)?

    private var labelWidth: CGFloat { TimelineDiagramView.labelWidth }
    private var rowHeight: CGFloat { TimelineDiagramView.rowHeight }
    private var axisHeight: CGFloat { TimelineDiagramView.axisHeight }

    var body: some View {
        GeometryReader { geo in
            let track = max(geo.size.width - labelWidth, 120)
            let span = max(domain.upperBound.timeIntervalSince(domain.lowerBound), 1)
            let x: (Date) -> CGFloat = { labelWidth + CGFloat($0.timeIntervalSince(domain.lowerBound) / span) * track }
            let bodyHeight = CGFloat(rows.dated.count) * rowHeight
            ZStack(alignment: .topLeading) {
                // Rows: selection, label, separator.
                ForEach(Array(rows.dated.enumerated()), id: \.element.item.id) { index, row in
                    rowBackground(row, index: index, width: geo.size.width)
                }
                // Gridlines and date labels.
                ForEach(Self.ticks(in: domain, width: track, hours: rows.hasTimes), id: \.self) { tick in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 1, height: bodyHeight)
                        .offset(x: x(tick), y: axisHeight)
                    Text(Self.tickLabel(tick))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: x(tick) + 3, y: 4)
                }
                marker("Meeting", at: x(meetingDate), color: .secondary, dashed: true, height: bodyHeight)
                if let today, Calendar.current.startOfDay(for: today) != Calendar.current.startOfDay(for: meetingDate) {
                    marker("Today", at: x(today), color: .red, dashed: false, height: bodyHeight)
                }
                // Marks.
                ForEach(Array(rows.dated.enumerated()), id: \.element.item.id) { index, row in
                    mark(row, x: x, width: geo.size.width)
                        .frame(height: rowHeight)
                        .offset(y: axisHeight + CGFloat(index) * rowHeight)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func rowBackground(_ row: TimelineRows.Row, index: Int, width: CGFloat) -> some View {
        let item = row.item
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let owner = item.owner?.nonEmpty {
                        Text(owner)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(item.owner.map { "\(item.name) — \($0)" } ?? item.name)
                .padding(.leading, 8)
                .frame(width: labelWidth - 12, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(height: rowHeight - 1)
            Divider().opacity(0.5)
        }
        .frame(width: width)
        .background(item.id == selectedItemID ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onSelect?(item.id) }
        .offset(y: axisHeight + CGFloat(index) * rowHeight)
    }

    /// The date sits right of its mark; where that would run off the chart
    /// — a late bar with a long label, in a fixed-width export — it sits
    /// left of the mark instead.
    @ViewBuilder
    private func mark(_ row: TimelineRows.Row, x: (Date) -> CGFloat, width: CGFloat) -> some View {
        let item = row.item
        let isSelected = item.id == selectedItemID
        let tint = isSelected ? Color.accentColor : (item.isMilestone == true ? Color.purple : Color.teal)
        let opacity = item.isEstimated ? 0.5 : 0.9
        let text = dateLabel(item, row)
        let label = Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
        let isBar = row.start.flatMap { start in row.due.map { start < $0 } } ?? false
        let shape = Group {
            if isBar, let start = row.start, let due = row.due {
                Capsule()
                    .fill(tint.opacity(opacity))
                    .frame(width: max(x(due) - x(start), 8), height: 12)
            } else if item.isMilestone == true {
                Diamond().fill(tint.opacity(opacity)).frame(width: 14, height: 14)
            } else {
                Circle().fill(tint.opacity(opacity)).frame(width: 12, height: 12).frame(width: 14)
            }
        }
        if let first = isBar ? row.start : (row.due ?? row.start) {
            let left = isBar ? x(first) : x(first) - 7
            let right = isBar ? max(x(row.due ?? first), left + 8) : left + 14
            let flips = Self.labelFlips(text, markLeft: left, markRight: right, chartWidth: width)
            if flips {
                // Ends at the mark's right edge, whatever the label measures.
                HStack(spacing: 6) {
                    label
                    shape
                }
                .frame(width: right, alignment: .trailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    shape
                    label
                }
                .offset(x: left)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    /// Left of the mark when the label would run off the right edge and
    /// fits between the name column and the mark. Its width is estimated,
    /// a little generously, rather than measured.
    static func labelFlips(_ text: String, markLeft: CGFloat, markRight: CGFloat, chartWidth: CGFloat) -> Bool {
        let width = CGFloat(text.count) * 6 + 4
        return markRight + 6 + width > chartWidth && markLeft - 6 - width >= TimelineDiagramView.labelWidth
    }

    private func dateLabel(_ item: TimelineDiagram.Item, _ row: TimelineRows.Row) -> String {
        var text: String
        if let start = row.start, let due = row.due, start < due {
            let sameDay = Calendar.current.isDate(start, inSameDayAs: due)
            let end = sameDay && row.dueHasTime
                ? due.formatted(date: .omitted, time: .shortened)
                : TimelineRows.format(due, withTime: row.dueHasTime)
            text = "\(TimelineRows.format(start, withTime: row.startHasTime)) – \(end)"
        } else if let due = row.due {
            text = TimelineRows.format(due, withTime: row.dueHasTime)
        } else {
            text = row.start.map { TimelineRows.format($0, withTime: row.startHasTime) } ?? ""
        }
        if item.isEstimated { text += " (est.)" }
        return text
    }

    private func marker(_ title: String, at x: CGFloat, color: Color, dashed: Bool, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: axisHeight - 4))
                path.addLine(to: CGPoint(x: x, y: axisHeight + height))
            }
            .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: dashed ? 1 : 1.5, dash: dashed ? [3, 3] : []))
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
                .fixedSize()
                .padding(.horizontal, 3)
                .background(.background, in: RoundedRectangle(cornerRadius: 3))
                .offset(x: x + 2, y: axisHeight - 2)
        }
        .allowsHitTesting(false)
    }

    /// Midnight shows the day; any other tick, the hour.
    static func tickLabel(_ tick: Date) -> String {
        tick == Calendar.current.startOfDay(for: tick)
            ? tick.formatted(.dateTime.month(.abbreviated).day())
            : tick.formatted(.dateTime.hour())
    }

    /// Hour, day, week or month gridlines, whichever leaves room for the
    /// labels; hours only when the timeline gave times.
    static func ticks(in domain: ClosedRange<Date>, width: CGFloat, hours: Bool = false) -> [Date] {
        let calendar = Calendar.current
        let room = Double(max(width / 64, 1))
        let spanHours = domain.upperBound.timeIntervalSince(domain.lowerBound) / 3_600
        if hours, let step = [1, 2, 3, 6, 12].first(where: { spanHours / Double($0) <= room }) {
            // On the hour, at multiples of the step from midnight.
            var tick = calendar.dateInterval(of: .hour, for: domain.lowerBound)?.end ?? domain.lowerBound
            while calendar.component(.hour, from: tick) % step != 0 {
                tick = calendar.date(byAdding: .hour, value: 1, to: tick) ?? domain.upperBound
            }
            var ticks: [Date] = []
            while tick < domain.upperBound {
                ticks.append(tick)
                tick = calendar.date(byAdding: .hour, value: step, to: tick) ?? domain.upperBound
            }
            return ticks
        }
        let days = max(spanHours / 24, 1)
        guard let first = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: domain.lowerBound)) else { return [] }
        if days / 30 > room {
            var month = calendar.dateInterval(of: .month, for: domain.lowerBound)?.end ?? first
            var ticks: [Date] = []
            let stride = max(Int((days / 30 / room).rounded(.up)), 1)
            while month < domain.upperBound {
                ticks.append(month)
                month = calendar.date(byAdding: .month, value: stride, to: month) ?? domain.upperBound
            }
            return ticks
        }
        let step = [1, 2, 7, 14].first { days / Double($0) <= room } ?? 30
        var day = first
        if step >= 7 {
            // Weeks start on the calendar's first weekday.
            while calendar.component(.weekday, from: day) != calendar.firstWeekday {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            }
        }
        var ticks: [Date] = []
        while day < domain.upperBound {
            ticks.append(day)
            day = calendar.date(byAdding: .day, value: step, to: day) ?? domain.upperBound
        }
        return ticks
    }
}

/// Pick a due date for something the meeting left undated.
private struct SetDateButton: View {
    let meetingDate: Date
    let onSet: (Date) -> Void

    @State private var isPicking = false
    @State private var date = Date.now

    var body: some View {
        Button("Set Date…") {
            date = max(meetingDate, Calendar.current.startOfDay(for: .now))
            isPicking = true
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            VStack(alignment: .trailing, spacing: 10) {
                DatePicker("Due", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    Button("Cancel") { isPicking = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Set") {
                        onSet(date)
                        isPicking = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }
}

/// The dated items as chart rows, with labels made unique — the chart's
/// category axis merges rows that share a name.
struct TimelineRows {
    struct Row {
        let item: TimelineDiagram.Item
        let label: String
        /// Parsed once here; the chart reads them on every render.
        let start: Date?
        let due: Date?
        var startHasTime: Bool { item.start.map(TimelineDiagram.hasTime) ?? false }
        var dueHasTime: Bool { item.due.map(TimelineDiagram.hasTime) ?? false }
    }

    let dated: [Row]
    /// Some item gave a time of day: the axis runs in hours.
    let hasTimes: Bool

    init(_ timeline: TimelineDiagram) {
        var counts: [String: Int] = [:]
        let hasTimes = timeline.shown.contains { $0.hasTime }
        self.hasTimes = hasTimes
        // Spelled out step by step: as one chain, CI's compiler gave up
        // type-checking it.
        typealias Entry = (item: TimelineDiagram.Item, start: Date?, due: Date?)
        func sortDate(_ entry: Entry) -> Date { entry.due ?? entry.start ?? .distantFuture }
        // Beside timed items, a due day alone means by the end of that day.
        func due(_ item: TimelineDiagram.Item) -> Date? {
            guard let date = item.dueDate else { return nil }
            guard hasTimes, let text = item.due, !TimelineDiagram.hasTime(text) else { return date }
            return Calendar.current.date(byAdding: .day, value: 1, to: date)?.addingTimeInterval(-60) ?? date
        }
        let entries: [Entry] = timeline.shown.map { item in (item: item, start: item.startDate, due: due(item)) }
        let parsed: [Entry] = entries
            .filter { $0.start != nil || $0.due != nil }
            .sorted { sortDate($0) < sortDate($1) }
        dated = parsed.map { entry in
            counts[entry.item.name, default: 0] += 1
            let n = counts[entry.item.name] ?? 1
            let label = n == 1 ? entry.item.name : "\(entry.item.name) (\(n))"
            return Row(item: entry.item, label: label, start: entry.start, due: entry.due)
        }
    }

    /// "Oct 15", or "Oct 15, 3:00 PM" when a time was given — in this
    /// Mac's zone.
    static func format(_ date: Date, withTime: Bool) -> String {
        withTime
            ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    func id(forLabel label: String) -> String? {
        dated.first { $0.label == label }?.item.id
    }

    /// From a little before the earliest date to a little after the latest,
    /// including the meeting (and today, on screen).
    func domain(including meetingDate: Date, today: Date?) -> ClosedRange<Date> {
        var dates = dated.flatMap { [$0.start, $0.due].compactMap { $0 } } + [meetingDate]
        if let today { dates.append(today) }
        let low = dates.min() ?? meetingDate
        let high = dates.max() ?? meetingDate
        let pad = max(high.timeIntervalSince(low) * 0.08, hasTimes ? 3_600 : 2 * 86_400)
        // Room on the right for the date beside the last mark.
        return low.addingTimeInterval(-pad)...high.addingTimeInterval(pad * 2)
    }
}

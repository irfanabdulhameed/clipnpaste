import Foundation

/// History mode: clips newest first, grouped by the day they were copied, each day under a 24 pt
/// header, the same card size and column count as the row.
public struct HistoryLayout: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        /// The start of the day.
        public let day: Date
        public let label: String
        /// The header's top in the scroll content.
        public let y: Int
        public let first: Int
        public let count: Int
    }

    public let sections: [Section]
    /// One per clip, in the order given.
    public let origins: [PanelGrid.Origin]
    /// Clip indexes per visual row, across sections, for ↑ and ↓.
    public let rows: [[Int]]
    /// Where the next card row would start (for the loading placeholders).
    public let endY: Int
    public let contentHeight: Int

    /// - Parameter dates: each clip's copy date, newest first.
    public init(dates: [Date], grid: PanelGrid, now: Date, calendar: Calendar = .current) {
        var sections: [Section] = []
        var origins: [PanelGrid.Origin] = []
        var rows: [[Int]] = []
        var y = PanelGrid.contentTop
        var i = 0
        while i < dates.count {
            let day = calendar.startOfDay(for: dates[i])
            var j = i
            while j < dates.count, calendar.isDate(dates[j], inSameDayAs: day) { j += 1 }
            let count = j - i
            sections.append(Section(day: day, label: DayLabel.text(for: day, now: now, calendar: calendar),
                                    y: y, first: i, count: count))
            let top = y + PanelGrid.headerHeight
            let firstRow = rows.count
            for k in 0..<count {
                let col = k % grid.columns, r = k / grid.columns
                origins.append(PanelGrid.Origin(x: grid.sidePadding + col * grid.pitchX, y: top + r * grid.pitchY,
                                                row: firstRow + r, col: col))
                if r + firstRow >= rows.count { rows.append([]) }
                rows[firstRow + r].append(i + k)
            }
            y = top + grid.gridRows(count: count) * grid.pitchY
            i = j
        }
        self.sections = sections
        self.origins = origins
        self.rows = rows
        endY = y
        contentHeight = dates.isEmpty ? 0 : y - grid.gap + CardLayout.bottomPadding
    }
}

/// "Today", "Yesterday", "Monday 26 October" (with the year when it isn't this year).
public enum DayLabel {
    public static func text(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let ago = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if ago == 0 { return "Today" }
        if ago == 1 { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
        f.dateFormat = sameYear ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        return f.string(from: day)
    }
}

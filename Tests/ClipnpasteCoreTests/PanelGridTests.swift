import Foundation
import Testing
@testable import ClipnpasteCore

@Suite struct PanelGridTests {
    /// 1920 × 1080 with a 1050 visible frame: 224 × 140 cards, 8 across, at most 3 rows.
    let g = PanelGrid(layout: CardLayout(visibleWidth: 1920, visibleHeight: 1050, screenHeight: 1080),
                      panelWidth: 1904, availableHeight: 1034)

    @Test func rowHeightsMatchThePlan() {
        #expect((1...3).map { g.height(rows: $0) } == [180, 332, 484])
        let q = PanelGrid(layout: CardLayout(visibleWidth: 2560, visibleHeight: 1410, screenHeight: 1440),
                          panelWidth: 2544, availableHeight: 1394)
        #expect((1...3).map { q.height(rows: $0) } == [240, 452, 664])
    }

    @Test func neverTallerThanThreeRows() {
        // 6 rows would fit on both screens; the panel stops at 3 (Irfan, 27 Oct 2026).
        #expect(g.maxRows == 3 && g.maxHeight == 484)
        let q = PanelGrid(layout: CardLayout(visibleWidth: 2560, visibleHeight: 1410, screenHeight: 1440),
                          panelWidth: 2544, availableHeight: 1394)
        #expect(q.maxRows == 3 && q.maxHeight == 664)
        // A short screen that fits only 2 rows keeps 2.
        let short = PanelGrid(layout: CardLayout(visibleWidth: 1920, visibleHeight: 400, screenHeight: 1080),
                              panelWidth: 1904, availableHeight: 384)
        #expect(short.maxRows == 2)
    }

    @Test func rowsShownAddARowOnceItIsHalfUncovered() {
        #expect(g.rowsShown(height: 180) == 1)
        #expect(g.rowsShown(height: 255) == 1)
        #expect(g.rowsShown(height: 257) == 2)
        #expect(g.rowsShown(height: 100) == 1)
        #expect(g.rowsShown(height: 5000) == 3)
    }

    @Test func snapProjectsTheReleaseSpeed() {
        // Released at 250 pt moving up at 800 pt/s: 250 + 96 = 346 → 2 rows.
        #expect(g.snapRows(height: 250, velocity: 800) == 2)
        // Same place, still: 250 → 1 row.
        #expect(g.snapRows(height: 250, velocity: 0) == 1)
        // A fast flick down from 3 rows lands on 1.
        #expect(g.snapRows(height: 484, velocity: -2500) == 1)
    }

    @Test func rubberBand() {
        #expect(RubberBand.offset(0) == 0)
        #expect(abs(RubberBand.offset(100) - 32.59) < 0.01)
        #expect(RubberBand.offset(100_000) < RubberBand.reach)
        #expect(RubberBand.apply(300, min: 180, max: 484) == 300)
        #expect(abs(RubberBand.apply(80, min: 180, max: 484) - (180 - 32.59)) < 0.01)
        #expect(abs(RubberBand.apply(584, min: 180, max: 484) - (484 + 32.59)) < 0.01)
        // Grows with the pull but ever more slowly.
        let a = RubberBand.offset(50), b = RubberBand.offset(100), c = RubberBand.offset(150)
        #expect(a < b && b < c && (b - a) > (c - b))
    }

    @Test func positions() {
        #expect(g.sidePadding == 14)
        #expect(g.rowOrigin(0) == .init(x: 14, y: 6, row: 0, col: 0))
        #expect(g.rowOrigin(3).x == 14 + 3 * 236)
        #expect(g.gridOrigin(9) == .init(x: 14 + 236, y: 6 + 152, row: 1, col: 1))
        #expect(g.rowContentWidth(count: 8) == 1904)
        #expect(g.gridContentHeight(count: 9) == 6 + 2 * 152 - 12 + 12)
        #expect(g.gridContentHeight(count: 0) == 0)
    }

    @Test func slotUnderThePointer() {
        // Row: the nearest whole position, clamped to the list.
        #expect(g.slot(cardX: 14, cardY: 6, grid: false, count: 12) == 0)
        #expect(g.slot(cardX: 14 + 236 * 2 + 100, cardY: 6, grid: false, count: 12) == 2)
        #expect(g.slot(cardX: 14 + 236 * 2 + 130, cardY: 6, grid: false, count: 12) == 3)
        #expect(g.slot(cardX: -400, cardY: 6, grid: false, count: 12) == 0)
        #expect(g.slot(cardX: 99_999, cardY: 6, grid: false, count: 12) == 11)
        // Grid: row and column, clamped to the columns and the list.
        #expect(g.slot(cardX: 14 + 236, cardY: 6 + 152, grid: true, count: 20) == 9)
        #expect(g.slot(cardX: 99_999, cardY: 6, grid: true, count: 20) == 7)
        #expect(g.slot(cardX: 14, cardY: 6 + 152 * 5, grid: true, count: 20) == 19)
    }

    @Test func reorderIndex() {
        let items = ["a", "b", "c", "d", "e"]
        #expect(Reorder.order(items, moving: 0, to: 2) == ["b", "c", "a", "d", "e"])
        #expect(Reorder.order(items, moving: 4, to: 0) == ["e", "a", "b", "c", "d"])
        #expect(Reorder.order(items, moving: 1, to: 1) == items)
        #expect(Reorder.order(items, moving: 1, to: 99) == ["a", "c", "d", "e", "b"])
        // The others part around the open slot.
        #expect((0..<4).map { Reorder.displayIndex($0, slot: 2) } == [0, 1, 3, 4])
    }

    @MainActor @Test func reorderMatchesTheStoreMove() {
        // The slot index is exactly what ClipStore.move(id:toIndex:) takes.
        let clips = DemoClips.make()
        let store = InMemoryClipStore(clips: clips)
        let ids = store.ordered(20).map(\.id)
        let shown = Reorder.order(ids, moving: 0, to: 3)
        store.move(id: ids[0], toIndex: 3)
        #expect(store.ordered(20).map(\.id) == shown)
    }

    @Test func tiltFromSpeed() {
        #expect(DragTilt.angle(velocityX: 0) == -6)
        #expect(DragTilt.angle(velocityX: 400) == -2)
        #expect(DragTilt.angle(velocityX: 5000) == 2)
        #expect(DragTilt.angle(velocityX: -5000) == -14)
    }

    @Test func velocityFromTheLast100ms() {
        var v = VelocityTracker()
        for i in 0...10 { v.add(time: Double(i) * 0.016, x: Double(i) * 8, y: 0) }
        let now = 10 * 0.016
        #expect(abs(v.velocity(at: now).x - 500) < 1)
        // Held still for 200 ms: no speed.
        #expect(v.velocity(at: now + 0.2).x == 0)
    }

    @Test func autoScrollNearTheEdges() {
        #expect(AutoScroll.speed(position: 500, lower: 0, upper: 1000) == 0)
        #expect(AutoScroll.speed(position: 0, lower: 0, upper: 1000) == -AutoScroll.maxSpeed)
        #expect(AutoScroll.speed(position: 1000, lower: 0, upper: 1000) == AutoScroll.maxSpeed)
        let half = AutoScroll.speed(position: 1000 - AutoScroll.zone / 2, lower: 0, upper: 1000)
        #expect(abs(half - AutoScroll.maxSpeed / 4) < 0.001)
    }
}

@Suite struct SpringTests {
    @Test func arriveShape() {
        // The plan's arrive token: 70% by 133 ms, 98.6% by 340 ms.
        #expect(abs(Spring.progress(duration: 0.34, at: 0.133) - 0.70) < 0.01)
        #expect(abs(Spring.progress(duration: 0.34, at: 0.34) - 0.986) < 0.001)
    }

    @Test func neverPassesTheTarget() {
        // A spring released with a strong push toward its target stops there instead of crossing.
        var x = 50.0, v = -2000.0
        let w = Spring.omega(duration: 0.34)
        var minX = x
        for _ in 0..<120 {
            (x, v) = Spring.step(offset: x, velocity: v, omega: w, dt: 1.0 / 120, side: 1)
            minX = min(minX, x)
        }
        #expect(minX >= 0)
        #expect(abs(x) < 0.01)
        // Without the guard the same spring would overshoot, so the guard is doing the work.
        var y = 50.0, u = -2000.0, minY = y
        for _ in 0..<120 {
            (y, u) = Spring.step(offset: y, velocity: u, omega: w, dt: 1.0 / 120)
            minY = min(minY, y)
        }
        #expect(minY < 0)
    }

    @Test func frameRateIndependent() {
        let w = Spring.omega(duration: 0.3)
        var a = (offset: 100.0, velocity: 0.0), b = (offset: 100.0, velocity: 0.0)
        for _ in 0..<12 { a = Spring.step(offset: a.offset, velocity: a.velocity, omega: w, dt: 1.0 / 60) }
        for _ in 0..<24 { b = Spring.step(offset: b.offset, velocity: b.velocity, omega: w, dt: 1.0 / 120) }
        #expect(abs(a.offset - b.offset) < 1e-9)
    }

    @Test func bezier() {
        let leave = CubicBezier(0.45, 0, 0.8, 0.4)
        #expect(leave(0) == 0 && leave(1) == 1)
        #expect(leave(0.5) < 0.2)
        #expect(abs(CubicBezier.linear(0.37) - 0.37) < 1e-6)
        let fadeIn = CubicBezier(0.333, 0, 0, 1)
        #expect(fadeIn(0.5) > 0.8)
    }
}

@Suite struct HistoryLayoutTests {
    let g = PanelGrid(columns: 8, cardWidth: 224, cardHeight: 140, sidePadding: 14, maxRows: 6)
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }

    func date(_ d: Int, _ h: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))!
    }

    @Test func groupsByDayWithHeaders() {
        let now = date(27, 18)
        var dates: [Date] = []
        for i in 0..<10 { dates.append(date(27, 17 - i)) }   // 10 today
        for i in 0..<3 { dates.append(date(26, 20 - i)) }    // 3 yesterday
        dates.append(date(24, 9))                             // 1 on Saturday
        let l = HistoryLayout(dates: dates, grid: g, now: now, calendar: cal)
        #expect(l.sections.map(\.label) == ["Today", "Yesterday", "Saturday 24 October"])
        #expect(l.sections.map(\.count) == [10, 3, 1])
        #expect(l.sections[0].y == 6)
        // Today: header, then two rows (8 + 2).
        #expect(l.origins[0] == .init(x: 14, y: 30, row: 0, col: 0))
        #expect(l.origins[9] == .init(x: 14 + 236, y: 30 + 152, row: 1, col: 1))
        #expect(l.sections[1].y == 30 + 2 * 152)
        #expect(l.origins[10] == .init(x: 14, y: 30 + 2 * 152 + 24, row: 2, col: 0))
        #expect(l.rows.map(\.count) == [8, 2, 3, 1])
        #expect(l.contentHeight == l.endY - 12 + 12)
    }

    @Test func emptyHistory() {
        let l = HistoryLayout(dates: [], grid: g, now: Date(), calendar: cal)
        #expect(l.sections.isEmpty && l.origins.isEmpty && l.contentHeight == 0)
    }

    @Test func dayLabels() {
        let now = date(27, 9)
        #expect(DayLabel.text(for: date(27, 1), now: now, calendar: cal) == "Today")
        #expect(DayLabel.text(for: date(26, 23), now: now, calendar: cal) == "Yesterday")
        #expect(DayLabel.text(for: date(26, 0), now: now, calendar: cal) == "Yesterday")
        #expect(DayLabel.text(for: date(19, 12), now: now, calendar: cal) == "Monday 19 October")
        let lastYear = cal.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 10))!
        #expect(DayLabel.text(for: lastYear, now: now, calendar: cal) == "Wednesday 31 December 2025")
    }
}

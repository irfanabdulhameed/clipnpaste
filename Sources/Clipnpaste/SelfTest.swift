import AppKit
import Carbon
import ClipnpasteCore

/// `--self-test` and `--scene`: drive the panel's own event router with synthetic keys, wheel
/// notches, clicks and drags, and log a PASS or FAIL for each step. Nothing is posted to the
/// system, nothing is pasted or copied (a paste is recorded instead), and no drag session is
/// started, so the clipboard, the real mouse and other apps are untouched.
extension PanelController {
    private final class Results {
        var passed = 0
        var failed = 0
    }

    func runSelfTest() async {
        let r = Results()
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { r.passed += 1 } else { r.failed += 1 }
            debugLog("self-test \(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — \(detail())")")
        }
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "") {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: panel.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)) {
                panel.sendEvent(e)
            }
        }
        var clock = ProcessInfo.processInfo.systemUptime
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint, after ms: Double = 16) {
            clock += ms / 1000
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: clock,
                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1) {
                panel.sendEvent(e)
            }
        }
        func click(_ p: NSPoint) {
            mouse(.leftMouseDown, p)
            mouse(.leftMouseUp, p)
        }
        func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        /// Until nothing moves (at most 2 s).
        func settle() async {
            let start = CACurrentMediaTime()
            await wait(40)
            while !MotionClock.shared.isIdle && CACurrentMediaTime() - start < 2 { await wait(16) }
            await wait(30)
            clock = max(clock, ProcessInfo.processInfo.systemUptime)
        }
        /// The middle of a card in window coordinates, from where it rests.
        func cardPoint(_ index: Int, dx: CGFloat = 0, dy: CGFloat = 0) -> NSPoint {
            let id = model.clips[index].id
            let rect = board.restingRect(id) ?? .zero
            let s = screenRect(ofContent: rect)
            return panel.convertPoint(fromScreen: NSPoint(x: s.midX + dx, y: s.midY + dy))
        }
        func pillPoint() -> NSPoint {
            let f = surface.frame
            return NSPoint(x: f.midX, y: f.maxY - 12)
        }
        // The glass height never passes its target: the highest and lowest value seen.
        var seenMax = -Double.infinity, seenMin = Double.infinity
        glass.h.probe = { v in seenMax = max(seenMax, v); seenMin = min(seenMin, v) }
        func resetProbe() { seenMax = -.infinity; seenMin = .infinity }
        func noOvershoot(_ name: String, from: Double, to: Double) {
            let over = to >= from ? seenMax - to : to - seenMin
            check("\(name): settles at \(Int(to)) pt with no overshoot", over <= 0.01 && abs(glass.h.v - to) < 0.01,
                  "overshoot \(String(format: "%.3f", over)) pt, now \(glass.h.v)")
        }

        let g = model.geometry
        let grid = g.grid
        await settle()
        check("opened", isOpen && model.selectedIndex == 0, "open \(isOpen), selected \(model.selectedIndex ?? -1)")

        // Day 1 steps, unchanged in what they check.
        for _ in 0..<3 { key(kVK_RightArrow) }
        check("→ ×3 selects 3", model.selectedIndex == 3)
        key(kVK_RightArrow, .command); await settle()
        let maxX = g.maxScroll(count: model.clips.count)
        check("⌘→ selects the last and scrolls to the end", model.selectedIndex == model.clips.count - 1 && abs(board.viewport.minX - maxX) < 1,
              "selected \(model.selectedIndex ?? -1), scroll \(board.viewport.minX) of \(maxX)")
        key(kVK_LeftArrow, .command); await settle()
        check("⌘← selects 0 and scrolls back", model.selectedIndex == 0 && board.viewport.minX == 0, "scroll \(board.viewport.minX)")
        let firstID = model.clips.first?.id
        key(kVK_RightArrow, [.command, .option]); await settle()
        check("⌥⌘→ moves the card one place", model.selectedIndex == 1 && model.clips.firstIndex { $0.id == firstID } == 1)
        key(kVK_Tab); check("Tab → copy", model.focus == .copy)
        key(kVK_Tab); check("Tab → remove", model.focus == .remove)
        key(kVK_Tab); check("Tab → History button", model.focus == .history && content.topBar.history.focused)
        key(kVK_Tab); check("Tab → card", model.focus == .card)
        key(kVK_Tab, .shift); check("⇧Tab → History button", model.focus == .history)
        key(kVK_Tab, .shift); check("⇧Tab → remove", model.focus == .remove)
        var count = model.clips.count
        key(kVK_Return); await settle()
        check("Return on Remove removes it", model.clips.count == count - 1 && model.selectedIndex == 1 && model.focus == .card)
        key(kVK_Delete); await settle()
        check("Delete removes the selected card", model.clips.count == count - 2 && model.selectedIndex == 1)
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0),
           let wheel = NSEvent(cgEvent: cg) {
            _ = route(wheel)
            await wait(600)
            check("a mouse wheel's notches scroll the row sideways", board.viewport.minX > 0, "scroll \(board.viewport.minX)")
        }
        board.scroll(to: .zero, instant: true); await settle()
        let removePoint = NSPoint(x: surface.frame.minX + CGFloat(g.sidePadding + g.cardWidth - 16),
                                  y: surface.frame.maxY - CGFloat(g.cardTop + 13))
        click(removePoint); await settle()
        check("a click on card 0's Remove removes it", model.clips.count == count - 3)
        count = model.clips.count

        // A click pastes; a press that moves less than 4 pt is still a click.
        var pasted: UUID?
        pasteInterceptor = { pasted = $0 }
        let ci = model.clips.firstIndex { $0.kind == .text } ?? 1
        let clickTarget = model.clips[ci].id
        mouse(.leftMouseDown, cardPoint(ci))
        mouse(.leftMouseDragged, cardPoint(ci, dx: 3))
        mouse(.leftMouseUp, cardPoint(ci, dx: 3))
        check("a press that moves 3 pt still pastes, with no drag", pasted == clickTarget && drag == nil)

        // Drag to reorder in the row.
        let moving = model.clips[0].id
        let order0 = model.clips.map(\.id)
        // The card's slot moves as the others part, so the path is fixed from where it started.
        let a0 = cardPoint(0)
        func from(_ p: NSPoint, dx: CGFloat, dy: CGFloat = 0) -> NSPoint { NSPoint(x: p.x + dx, y: p.y + dy) }
        mouse(.leftMouseDown, a0)
        mouse(.leftMouseDragged, from(a0, dx: 2))
        check("2 pt is not a drag yet", drag == nil)
        let steps = 14
        for i in 1...steps {
            mouse(.leftMouseDragged, from(a0, dx: CGFloat(grid.pitchX) * 2.4 * CGFloat(i) / CGFloat(steps), dy: 6))
            await wait(16)
        }
        await wait(120)
        let pv = drag?.preview
        check("lift: a drag with its preview window", drag != nil && pv?.window.isVisible == true)
        check("lift: the preview window ignores the mouse", pv?.window.ignoresMouseEvents == true)
        check("lift: the card is a ghost in its slot", board.ghostID == moving)
        if Motion.reduce {
            check("lift under Reduce Motion: shadow only, no scale or tilt",
                  pv?.sc.v == 1 && pv?.rot.v == 0 && pv?.lift.v == 1, "scale \(pv?.sc.v ?? 0), tilt \(pv?.rot.v ?? 0)")
        } else {
            check("lift: the preview is scaled 1.04 and tilted within −14…+2°",
                  abs((pv?.sc.v ?? 0) - 1.04) < 0.01 && (pv.map { $0.rot.v >= -14 && $0.rot.v <= 2 } ?? false),
                  "scale \(pv?.sc.v ?? 0), tilt \(pv?.rot.v ?? 0)")
        }
        check("the slot under the pointer is 2", drag?.slot == 2, "slot \(drag?.slot ?? -1)")
        await wait(600)
        let neighbour = order0[1]
        let x0 = CGFloat(grid.rowOrigin(0).x)
        check("the others part on settle: card 1 slid to place 0",
              board.restingRect(neighbour)?.minX == x0 && abs((board.currentRect(neighbour)?.minX ?? -99) - x0) < 0.5,
              "at \(board.currentRect(neighbour)?.minX ?? -1)")
        mouse(.leftMouseUp, from(a0, dx: CGFloat(grid.pitchX) * 2.4, dy: 6))
        await settle()
        check("release places it at 2 in the panel and the store",
              model.clips.firstIndex { $0.id == moving } == 2 && store.ordered(Self.clipLimit).firstIndex { $0.id == moving } == 2)
        check("the preview window is gone and the ghost is back", drag == nil && pv?.window.isVisible == false && board.ghostID == nil)
        check("nothing was pasted by the drag", pasted == clickTarget)

        // Esc drops it back where it was.
        let order1 = model.clips.map(\.id)
        let t1 = model.clips.firstIndex { $0.kind == .text } ?? 0
        let a1 = cardPoint(t1)
        mouse(.leftMouseDown, a1)
        for i in 1...10 {
            mouse(.leftMouseDragged, from(a1, dx: CGFloat(grid.pitchX) * 3.2 * CGFloat(i) / 10))
            await wait(16)
        }
        check("dragging over slot \(t1 + 3) opens it", drag?.slot == t1 + 3, "slot \(drag?.slot ?? -1)")
        key(kVK_Escape); await settle()
        check("Esc flies it back: order unchanged, panel open", model.clips.map(\.id) == order1 && drag == nil && isOpen)
        mouse(.leftMouseUp, a1)

        // ⌥↑ / ⌥↓ snap to whole rows on settle, with no overshoot.
        resetProbe()
        let h1 = glass.h.v
        key(kVK_UpArrow, .option); key(kVK_UpArrow, .option); await settle()
        check("⌥↑ ×2 → 3 rows, grid", rows == 3 && model.mode == .grid)
        noOvershoot("⌥↑", from: h1, to: Double(grid.height(rows: 3)))
        key(kVK_UpArrow, .option); await settle()
        check("⌥↑ stops at 3 rows", rows == 3 && grid.maxRows == 3 && abs(glass.h.v - Double(grid.height(rows: 3))) < 0.01)
        check("the window fits the glass again", abs(panel.frame.height - CGFloat(PanelGeometry.inset + grid.height(rows: 3) + PanelGeometry.shadowRoom)) < 1,
              "window \(panel.frame.height)")

        // ↑ and ↓ move between rows.
        selectIndex(1)
        key(kVK_DownArrow); check("↓ selects the card below (1 → \(1 + grid.columns))", model.selectedIndex == 1 + grid.columns)
        key(kVK_DownArrow)
        let third = min(1 + 2 * grid.columns, model.clips.count - 1)
        let expect = model.clips.count > 2 * grid.columns ? third : 1 + grid.columns
        check("↓ again (or stays on the last row)", model.selectedIndex == expect, "selected \(model.selectedIndex ?? -1)")
        key(kVK_UpArrow); key(kVK_UpArrow)
        check("↑ ×2 back to the top row", model.selectedIndex == 1)

        resetProbe()
        let h3 = glass.h.v
        key(kVK_DownArrow, .option); key(kVK_DownArrow, .option); await settle()
        check("⌥↓ ×2 → 1 row, row mode", rows == 1 && model.mode == .row)
        noOvershoot("⌥↓", from: h3, to: Double(grid.height(rows: 1)))

        // The pill: 1:1 tracking, a slow release snaps to the nearest row.
        resetProbe()
        let p0 = pillPoint()
        mouse(.leftMouseDown, p0)
        check("pill pressed", pill != nil && content.topBar.pill.look == .pressed)
        let lift = CGFloat(grid.pitchY) * 1.3
        var tracked = true
        for i in 1...20 {
            let dy = lift * CGFloat(i) / 20
            mouse(.leftMouseDragged, NSPoint(x: p0.x, y: p0.y + dy), after: 16)
            if abs(glass.h.v - (Double(grid.minHeight) + Double(dy))) > 0.01 { tracked = false }
            await wait(16)
        }
        check("pill: the height follows the pointer 1:1", tracked)
        check("pill: the second row came in", board.rowsShown == 2 && model.mode == .grid)
        await wait(150)
        resetProbe()
        mouse(.leftMouseUp, NSPoint(x: p0.x, y: p0.y + lift), after: 150)
        await settle()
        check("pill: a still release snaps to 2 rows", rows == 2 && abs(glass.h.v - Double(grid.height(rows: 2))) < 0.01, "rows \(rows), h \(glass.h.v)")
        noOvershoot("pill snap", from: Double(grid.minHeight) + Double(lift), to: Double(grid.height(rows: 2)))

        // Past the lower limit it rubber-bands, then returns to the limit.
        let p1 = pillPoint()
        mouse(.leftMouseDown, p1)
        let pull = CGFloat(grid.height(rows: 2) - grid.minHeight) + 100
        for i in 1...12 {
            mouse(.leftMouseDragged, NSPoint(x: p1.x, y: p1.y - pull * CGFloat(i) / 12))
            await wait(16)
        }
        let banded = Motion.reduce ? Double(grid.minHeight) : Double(grid.minHeight) - RubberBand.offset(100)
        check("pill: 100 pt past one row shows \(String(format: "%.1f", banded)) pt\(Motion.reduce ? " (hard stop)" : " (rubber band)")",
              abs(glass.h.v - banded) < 0.1, "h \(glass.h.v)")
        resetProbe()
        mouse(.leftMouseUp, NSPoint(x: p1.x, y: p1.y - pull), after: 150)
        await settle()
        check("pill: back to 1 row", rows == 1 && model.mode == .row)
        noOvershoot("rubber band return", from: banded, to: Double(grid.minHeight))

        // A fast flick up past 3 rows rubber-bands and settles at 3.
        let p2 = pillPoint()
        mouse(.leftMouseDown, p2)
        let flick = CGFloat(grid.maxHeight - grid.minHeight) + 60
        for i in 1...6 {
            mouse(.leftMouseDragged, NSPoint(x: p2.x, y: p2.y + flick * CGFloat(i) / 6), after: 12)
        }
        if Motion.reduce {
            check("pill under Reduce Motion: a hard stop at 3 rows", glass.h.v == Double(grid.maxHeight))
        } else {
            check("pill: past the top it rubber-bands", glass.h.v > Double(grid.maxHeight) && glass.h.v < Double(grid.maxHeight) + RubberBand.reach)
        }
        resetProbe()
        mouse(.leftMouseUp, NSPoint(x: p2.x, y: p2.y + flick), after: 12)
        await settle()
        check("pill: settles at 3 rows, the most", rows == 3 && grid.maxRows == 3)
        noOvershoot("rubber band top", from: Double(grid.maxHeight) + 30, to: Double(grid.maxHeight))
        check("rows are remembered", savedRows() == grid.maxRows)
        for _ in 1..<grid.maxRows { key(kVK_DownArrow, .option) }
        await settle()
        check("⌥↓ back to 1 row", rows == 1)

        // History: ⌘Y in, paging older clips as you scroll, ⌘Y out.
        let now = Date()
        for i in 0..<300 {
            let text = "Older clip \(i + 1): notes from the archive, item \(300 - i)."
            store.insertOrBump(Clip(kind: .text, plainText: text, sourceBundleID: "com.apple.Notes", sourceAppName: "Notes",
                                    createdAt: now.addingTimeInterval(-86_400 * (2 + Double(i / 30)) - Double(i) * 60),
                                    contentHash: DemoClips.hash(text)))
        }
        await settle()
        // With 2–3 rows, the clips past what fits scroll down inside the panel.
        key(kVK_UpArrow, .option); key(kVK_UpArrow, .option); await settle()
        key(kVK_RightArrow, .command); await settle()
        let lastRect = model.selectedID.flatMap { board.restingRect($0) } ?? .zero
        let view = board.viewport
        check("3 rows: ⌘→ scrolls the grid down to the last card", rows == 3 && view.minY > 0 && view.contains(lastRect),
              "rows \(rows), scroll \(view.minY), card \(lastRect)")
        check("3 rows: the grid scrolls down, not sideways", view.minX == 0 && board.contentSize.width == CGFloat(g.width))
        key(kVK_LeftArrow, .command); await settle()
        check("3 rows: ⌘← scrolls back to the top", board.viewport.minY == 0)
        key(kVK_DownArrow, .option); key(kVK_DownArrow, .option); await settle()
        let total = store.count
        resetProbe()
        let hRow = glass.h.v
        key(kVK_ANSI_Y, .command, "y")
        await settle()
        check("⌘Y enters history", model.mode == .history && content.topBar.history.selected && content.topBar.pill.isHidden)
        noOvershoot("history entry (3 rows tall)", from: hRow, to: Double(grid.height(rows: 3)))
        check("history is by copy date, newest first",
              zip(model.clips, model.clips.dropFirst()).allSatisfy { $0.createdAt >= $1.createdAt })
        let firstLoad = history.loaded.count
        check("history pages \(Self.historyPage) at a time (\(firstLoad) loaded of \(total))",
              firstLoad >= Self.historyPage && firstLoad < total && firstLoad % Self.historyPage == 0)
        var pages = 0
        while history.loaded.count < total && pages < 20 {
            let before = history.loaded.count
            board.scroll(to: CGPoint(x: 0, y: board.maxScroll.y), instant: true)
            await wait(120)
            await settle()
            if history.loaded.count == before { break }
            pages += 1
        }
        check("scrolling to the end pages in every older clip (\(pages) pages)", history.loaded.count == total && !history.hasMore,
              "\(history.loaded.count) of \(total)")
        board.scroll(to: .zero, instant: true)
        selectIndex(0)
        key(kVK_DownArrow)
        check("↓ in history goes to the next row", (model.selectedIndex ?? 0) > 0)
        let a2 = cardPoint(model.clips.firstIndex { $0.kind == .text } ?? 0)
        mouse(.leftMouseDown, a2)
        for i in 1...8 {
            mouse(.leftMouseDragged, from(a2, dx: CGFloat(grid.pitchX) * 2 * CGFloat(i) / 8))
            await wait(16)
        }
        check("history: a card lifts but no slot opens", drag != nil && drag?.reorderable == false && drag?.slot == drag?.from)
        let historyOrder = model.clips.map(\.id)
        mouse(.leftMouseUp, from(a2, dx: CGFloat(grid.pitchX) * 2))
        await settle()
        check("history: released, nothing reorders", model.clips.map(\.id) == historyOrder && drag == nil)
        resetProbe()
        let hHist = glass.h.v
        key(kVK_ANSI_Y, .command, "y")
        await settle()
        check("⌘Y leaves history, back to the row", model.mode == .row && rows == 1 && !content.topBar.pill.isHidden && !content.topBar.history.selected)
        noOvershoot("history exit", from: hHist, to: Double(grid.height(rows: 1)))
        key(kVK_ANSI_Y, .command, "y"); await settle()
        key(kVK_Escape); await settle()
        check("Esc in history closes the panel", !isOpen)
        pasteInterceptor = nil
        glass.h.probe = nil

        debugLog("self-test done: \(r.passed) passed, \(r.failed) failed")
        showToast(on: screen)
        debugLog("toast shown at \(toast.frame) on visible \(screen?.visibleFrame ?? .zero)")
    }

    /// `--scene NAME`: holds the panel in one state for a screenshot.
    func showScene(_ name: String) async {
        func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        var clock = ProcessInfo.processInfo.systemUptime
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
            clock += 0.016
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: clock,
                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1) {
                panel.sendEvent(e)
            }
        }
        func cardPoint(_ index: Int, dx: CGFloat = 0, dy: CGFloat = 0) -> NSPoint {
            let s = screenRect(ofContent: board.restingRect(model.clips[index].id) ?? .zero)
            return panel.convertPoint(fromScreen: NSPoint(x: s.midX + dx, y: s.midY + dy))
        }
        await wait(300)
        let grid = model.geometry.grid
        let f = surface.frame
        switch name {
        case "pill-hover":
            content.topBar.pill.setLook(.hover)
        case "pill-press":
            content.topBar.pill.setLook(.pressed)
        case "pill-limit":
            let p = NSPoint(x: f.midX, y: f.maxY - 12)
            mouse(.leftMouseDown, p)
            let up = CGFloat(grid.maxHeight - grid.minHeight) + 140
            for i in 1...20 { mouse(.leftMouseDragged, NSPoint(x: p.x, y: p.y + up * CGFloat(i) / 20)); await wait(16) }
        case "grid3":
            stepRows(1); await wait(400); stepRows(1)
        case "history":
            toggleHistory()
        case "reopen":
            for _ in 0..<3 {
                close(); await wait(300)
                open(); await wait(300)
            }
        case "drag", "strip":
            let a = cardPoint(1)
            mouse(.leftMouseDown, a)
            let dy: CGFloat = name == "strip" ? CGFloat(grid.cardHeight) + 80 : 10
            for i in 1...16 {
                let k = CGFloat(i) / 16
                mouse(.leftMouseDragged, NSPoint(x: a.x + CGFloat(grid.pitchX) * 1.6 * k, y: a.y + dy * k))
                await wait(16)
            }
        default:
            debugLog("unknown scene \(name)")
        }
        await wait(700)
        debugLog("scene \(name) ready: glass \(glassScreenRect), rows \(rows), mode \(model.mode), strip \(strip), drag \(drag != nil)")
    }
}

import AppKit
import Carbon
import ImageIO
import UniformTypeIdentifiers
import ClipnpasteCore

/// Drives the panel with synthetic events for the checks below (the same way `runSelfTest` does).
@MainActor
private final class Driver {
    unowned let c: PanelController
    private var clock = ProcessInfo.processInfo.systemUptime

    init(_ c: PanelController) { self.c = c }

    func key(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "") {
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: c.panel.windowNumber, context: nil, characters: chars,
                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)) {
            c.panel.sendEvent(e)
        }
    }

    func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
        clock = max(clock + 0.016, ProcessInfo.processInfo.systemUptime)
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: clock,
                                      windowNumber: c.panel.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1) {
            c.panel.sendEvent(e)
        }
    }

    func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// `n` display frames. Unlike a sleep, never stretched when the run is at background priority.
    func frames(_ n: Int) async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            var left = n
            var hook: Int?
            hook = MotionClock.shared.addHook { _ in
                left -= 1
                guard left <= 0, let h = hook else { return }
                MotionClock.shared.removeHook(h)
                hook = nil
                k.resume()
            }
        }
    }

    /// Until nothing moves (at most 2 s).
    func settle() async {
        let start = CACurrentMediaTime()
        await wait(40)
        while !MotionClock.shared.isIdle && CACurrentMediaTime() - start < 2 { await wait(16) }
        await wait(30)
    }

    /// A point on card `index` (where it rests), in window coordinates, `dy` down from its top.
    func cardPoint(_ index: Int, fromRight: CGFloat? = nil, down: CGFloat? = nil) -> NSPoint {
        let rect = c.board.restingRect(c.model.clips[index].id) ?? .zero
        let s = c.screenRect(ofContent: rect)
        let x = fromRight.map { s.maxX - $0 } ?? s.midX
        let y = down.map { s.maxY - $0 } ?? s.midY
        return c.panel.convertPoint(fromScreen: NSPoint(x: x, y: y))
    }

    func insertText(_ text: String) -> Clip {
        c.store.insertOrBump(Clip(kind: .text, plainText: text, sourceBundleID: "com.apple.Notes", sourceAppName: "Notes",
                                  contentHash: DemoClips.hash(text)))
    }
}

private func fmt(_ x: Double) -> String { String(format: "%.3f", x) }

extension PanelController {
    typealias Check = (String, Bool, String) -> Void

    // MARK: ↑ and ↓

    /// ↑ and ↓ in a 3-row and a 2-row panel. Expectations come from the grid itself, so they hold
    /// whatever the screen's column count. Starts and ends at 3 rows.
    func gridNavigationChecks(_ check: Check) async {
        let d = Driver(self)
        let cols = model.geometry.grid.columns
        // Three real rows, the last one short.
        let needed = 2 * cols + 2
        if model.clips.count < needed {
            for i in 0..<(needed - model.clips.count) { _ = d.insertText("Row filler \(i + 1) for the ↑ ↓ checks.") }
            await d.settle()
        }
        let n = model.clips.count
        /// The card ↓ (`dir` 1) or ↑ (−1) from `i`: the same column, or the last card of a short row.
        func vertical(_ i: Int, _ dir: Int) -> Int {
            let r = i / cols + dir
            guard r >= 0, r * cols < n else { return i }
            return min(r * cols + i % cols, n - 1)
        }
        func sel() -> String { "selected \(model.selectedIndex ?? -1) of \(n), \(cols) columns" }

        selectIndex(1)
        d.key(kVK_DownArrow)
        check("↓ selects the card below (1 → \(1 + cols))", model.selectedIndex == 1 + cols, sel())
        d.key(kVK_DownArrow)
        check("↓ again selects the third row (→ \(1 + 2 * cols))", model.selectedIndex == 1 + 2 * cols, sel())
        d.key(kVK_UpArrow); d.key(kVK_UpArrow)
        check("↑ ×2 back to the top row", model.selectedIndex == 1, sel())
        let last = 2 * cols - 1, below = vertical(last, 1)
        selectIndex(last)
        d.key(kVK_DownArrow)
        check("↓ from the last column onto a short row picks its last card (\(last) → \(below))", model.selectedIndex == below, sel())
        d.key(kVK_DownArrow)
        check("↓ on the last row stays", model.selectedIndex == below, sel())
        d.key(kVK_UpArrow)
        check("↑ goes to the same column in the row above (→ \(vertical(below, -1)))", model.selectedIndex == vertical(below, -1), sel())
        await d.settle()

        // A real 2-row panel: ↓ into the third row scrolls it into view, ↑ scrolls back.
        d.key(kVK_DownArrow, .option); await d.settle()
        selectIndex(1); await d.settle()
        d.key(kVK_DownArrow); d.key(kVK_DownArrow); await d.settle()
        let r3 = model.selectedID.flatMap { board.restingRect($0) } ?? .zero
        check("2 rows: ↓ ×2 reaches the third row and scrolls it into view",
              rows == 2 && model.selectedIndex == 1 + 2 * cols && board.viewport.contains(r3),
              "rows \(rows), \(sel()), view \(board.viewport), card \(r3)")
        d.key(kVK_UpArrow); d.key(kVK_UpArrow); await d.settle()
        check("2 rows: ↑ ×2 back to the top row, scrolled back", model.selectedIndex == 1 && board.viewport.minY == 0,
              "\(sel()), scroll \(board.viewport.minY)")
        d.key(kVK_UpArrow, .option); await d.settle()
    }

    // MARK: Card motion

    /// The sliding ring, pop and dip, remove, insert, the thumbnail blur-in, the copy checkmark, and
    /// no filters at rest. Starts and ends in the row, open.
    func cardMotionChecks(_ check: Check) async {
        let d = Driver(self)
        let rm = Motion.reduce
        let grid = model.geometry.grid
        let pitch = Double(grid.pitchX)
        let ring = board.ring
        func rest(_ i: Int) -> CGRect { board.restingRect(model.clips[i].id) ?? .zero }
        board.scroll(to: .zero, instant: true)
        selectIndex(0)
        await d.settle()
        await d.wait(150)

        // The ring slides 0 → 1 and the card pops.
        var xs: [Double] = []
        ring.probe = { xs.append(Double($0.x)) }
        let x0 = Double(rest(0).minX), x1 = Double(rest(1).minX), id1 = model.clips[1].id
        var popPeak = 1.0
        board.motions[id1]?.pop.probe = { popPeak = max(popPeak, $0) }
        d.key(kVK_RightArrow)
        let first = xs.last ?? -1
        await d.settle()
        let between = xs.filter { $0 > x0 + 0.5 && $0 < x1 - 0.5 }.count
        var furthest = xs.max() ?? 0
        var end = ring.drawn.map { Double($0.x) } ?? -1
        debugLog("motion: ring 0 → 1 (x \(x0) → \(x1)): \(xs.count) frames, \(between) between, furthest \(fmt(furthest)), overshoot \(fmt(max(0, furthest - x1))) pt; card pop peak \(fmt(popPeak))")
        if rm {
            check("Reduce Motion: → flips the ring to the next card", first == x1 && between == 0 && end == x1, "first \(first), \(between) between, end \(end)")
            check("Reduce Motion: the selected card doesn't pop", popPeak == 1, "peak \(popPeak)")
        } else {
            check("→: the ring slides from card 0 to card 1 (\(between) frames between)", first == x0 && between >= 3, "first \(first), \(between) between")
            check("→: the ring reaches card 1 with 0 overshoot", furthest <= x1 + 0.01 && abs(end - x1) < 0.01,
                  "furthest \(fmt(furthest)), end \(fmt(end)), target \(x1)")
            check("→: the selected card pops to 1.08 and back to 1", abs(popPeak - Motion.popPeak) < 0.001 && board.motions[id1]?.pop.v == 1,
                  "peak \(popPeak)")
        }
        board.motions[id1]?.pop.probe = nil

        // A held → (keys 40 ms apart): the ring re-aims mid-flight, keeping its speed; only the first press pops.
        await d.wait(150)
        xs = []
        let ids = (2...4).map { model.clips[$0].id }
        let x4 = Double(rest(4).minX)
        var pops = [1.0, 1.0, 1.0]
        for (k, id) in ids.enumerated() { board.motions[id]?.pop.probe = { pops[k] = max(pops[k], $0) } }
        var midFlight: [Bool] = []
        var gaps: [Double] = []
        var t0 = CACurrentMediaTime()
        d.key(kVK_RightArrow)
        for _ in 0..<2 {
            // Paced by display frames: the ring under way, then about 3 frames on, as a key repeat would.
            for _ in 0..<6 where !(ring.ox.velocity > 1) { await d.frames(1) }
            await d.frames(2)
            midFlight.append(ring.ox.busy && ring.ox.velocity > 1)
            gaps.append((CACurrentMediaTime() - t0) * 1000)
            t0 = CACurrentMediaTime()
            d.key(kVK_RightArrow)
        }
        await d.settle()
        let onward = zip(xs, xs.dropFirst()).allSatisfy { $1 >= $0 - 0.01 }
        furthest = xs.max() ?? 0
        end = ring.drawn.map { Double($0.x) } ?? -1
        debugLog("motion: held → 1 → 4 (x \(x4)), repeats \(gaps.map { Int($0) }) ms apart: \(xs.count) frames, mid-flight at the repeats \(midFlight), always onward \(onward), furthest \(fmt(furthest)), overshoot \(fmt(max(0, furthest - x4))) pt; pops \(pops.map(fmt))")
        if rm {
            check("Reduce Motion: a held → flips the ring along to card 4", model.selectedIndex == 4 && end == x4, "selected \(model.selectedIndex ?? -1), end \(end)")
            check("Reduce Motion: nothing pops on a held key", pops == [1, 1, 1], "\(pops)")
        } else {
            check("held →: the ring re-aims mid-flight, keeping its speed, never turning back", midFlight == [true, true] && onward,
                  "mid-flight \(midFlight), onward \(onward)")
            check("held →: it lands on card 4 with 0 overshoot", model.selectedIndex == 4 && furthest <= x4 + 0.01 && abs(end - x4) < 0.01,
                  "furthest \(fmt(furthest)), end \(fmt(end)), target \(x4)")
            check("held →: only the first press pops; the repeats glide", abs(pops[0] - Motion.popPeak) < 0.001 && pops[1] == 1 && pops[2] == 1,
                  "\(pops)")
        }
        for id in ids { board.motions[id]?.pop.probe = nil }

        // ⌘→: the ring and the scroll to the selection move in step on `quick`.
        await d.wait(150)
        var screen: [Double] = []
        ring.probe = { [unowned self] p in screen.append(Double(p.x) - self.board.scroller.sx.v) }
        let lastID = model.clips[model.clips.count - 1].id
        d.key(kVK_RightArrow, .command)
        // Under Reduce Motion both are there before the next frame is drawn.
        let atOnce = board.viewport.minX == board.maxScroll.x && ring.drawn.map { Double($0.x) } == Double((board.restingRect(lastID) ?? .zero).minX)
        await d.settle()
        let target = Double((board.restingRect(lastID) ?? .zero).minX - board.viewport.minX)
        let steady = zip(screen, screen.dropFirst()).allSatisfy { $1 >= $0 - 0.5 }
        let past = (screen.max() ?? 0) - target
        if rm {
            debugLog("motion: ⌘→ to card \(model.clips.count - 1): ring and row there before the next frame \(atOnce)")
        } else {
            debugLog("motion: ⌘→ to card \(model.clips.count - 1): ring on screen \(fmt(screen.first ?? 0)) → \(fmt(target)) over \(screen.count) frames, always onward \(steady), past the end by \(fmt(max(0, past))) pt")
        }
        if rm {
            check("Reduce Motion: ⌘→ moves the ring and the row at once", model.selectedID == lastID && atOnce && abs((screen.last ?? 0) - target) < 0.5,
                  "at once \(atOnce), last \(fmt(screen.last ?? 0)), target \(fmt(target))")
        } else {
            check("⌘→: the ring and the scroll move in step (the ring crosses the screen once, 0 overshoot)",
                  model.selectedID == lastID && steady && past <= 0.5 && abs((screen.last ?? 0) - target) < 0.5,
                  "onward \(steady), past \(fmt(past)), last \(fmt(screen.last ?? 0)), target \(fmt(target))")
        }
        ring.probe = nil
        d.key(kVK_LeftArrow, .command)
        await d.settle()

        // Press a card: it dips to 0.97 and holds; a click then selects it without a pop.
        let pid = model.clips[2].id
        var dipMin = 1.0, dipMax = 1.0, clickPop = 1.0
        board.motions[pid]?.dip.probe = { dipMin = min(dipMin, $0); dipMax = max(dipMax, $0) }
        board.motions[pid]?.pop.probe = { clickPop = max(clickPop, $0) }
        d.mouse(.leftMouseDown, d.cardPoint(2))
        await d.wait(120)
        let held = board.motions[pid]?.dip.v ?? 0
        let pressedState = model.state(for: pid).pressed
        d.mouse(.leftMouseUp, d.cardPoint(2))
        await d.settle()
        if rm {
            check("Reduce Motion: a pressed card darkens instead of dipping", pressedState && dipMin == 1, "pressed \(pressedState), dip \(dipMin)")
        } else {
            check("a pressed card dips to 0.97 and holds; released, it springs back to 1 with no overshoot",
                  pressedState && abs(held - Motion.dipCard) < 0.001 && dipMax <= 1 && board.motions[pid]?.dip.v == 1,
                  "held \(held), max \(dipMax)")
        }
        check("a click selects the card with no pop (the paste closes the panel)", model.selectedID == pid && clickPop == 1, "pop \(clickPop)")
        board.motions[pid]?.dip.probe = nil
        board.motions[pid]?.pop.probe = nil

        // The remove button: hover pops 1.08, a press dips to 0.92 and holds, released off it nothing happens.
        let bid = model.clips[3].id
        model.setHover(bid, nil)
        await d.settle()
        let look = board.motions[bid]?.cell?.look
        var hoverPeak = 1.0, pressLow = 1.0, releaseHigh = 0.0
        look?.remove.probe = { hoverPeak = max(hoverPeak, $0) }
        model.setHover(bid, .remove)
        await d.settle()
        look?.remove.probe = { pressLow = min(pressLow, $0) }
        let count0 = store.count
        d.mouse(.leftMouseDown, d.cardPoint(3, fromRight: 16, down: 13))
        await d.wait(120)
        let buttonHeld = look?.remove.v ?? 0
        let buttonPressed = model.state(for: bid).pressedButton == .remove
        look?.remove.probe = { releaseHigh = max(releaseHigh, $0) }
        d.mouse(.leftMouseUp, d.cardPoint(3, down: 70))
        await d.settle()
        model.setHover(nil, nil)
        look?.remove.probe = nil
        if rm {
            check("Reduce Motion: the remove button flips on hover and darkens when pressed, no pop or dip",
                  buttonPressed && hoverPeak == 1 && pressLow == 1, "pressed \(buttonPressed), peak \(hoverPeak), low \(pressLow)")
        } else {
            check("the remove button pops 1.08 on hover, dips to 0.92 while held, springs back with no overshoot",
                  buttonPressed && abs(hoverPeak - Motion.popPeak) < 0.001 && abs(buttonHeld - Motion.dipControl) < 0.001
                      && releaseHigh <= 1 && look?.remove.v == 1,
                  "peak \(hoverPeak), held \(buttonHeld), release max \(releaseHigh)")
        }
        check("released off the button, nothing is removed", store.count == count0, "\(count0) → \(store.count)")

        // ⌘C: a hard cut to the checkmark inside the 1.08 pop; it holds 1.5 s and cuts back with no pop.
        var copied: UUID?
        copyInterceptor = { copied = $0 }
        selectIndex(0)
        await d.settle()
        let cid = model.clips[0].id
        let clook = board.motions[cid]?.cell?.look
        var copyPeak = 1.0
        clook?.copy.probe = { copyPeak = max(copyPeak, $0) }
        let copiedAt = CACurrentMediaTime()
        d.key(kVK_ANSI_C, .command, "c")
        let cut = model.marks[cid] == .done && model.state(for: cid).mark == .done
        await d.wait(1000)
        let holds = model.marks[cid] == .done
        let peak = copyPeak
        copyPeak = 1
        var heldFor = 0.0
        for _ in 0..<150 where heldFor == 0 {
            await d.frames(1)
            if model.marks[cid] == nil { heldFor = CACurrentMediaTime() - copiedAt }
        }
        let reverted = model.marks[cid] == nil
        debugLog("motion: copy checkmark held \(Int(heldFor * 1000)) ms, pop peak \(fmt(peak))")
        clook?.copy.probe = nil
        copyInterceptor = nil
        check(rm ? "Reduce Motion: ⌘C hard-cuts the copy button to the checkmark, no pop" : "⌘C hard-cuts the copy button to the checkmark inside a 1.08 pop",
              copied == cid && cut && (rm ? peak == 1 : abs(peak - Motion.popPeak) < 0.001), "copied \(copied == cid), cut \(cut), peak \(peak)")
        check("the checkmark holds 1.5 s, then hard-cuts back to the copy symbol with no pop",
              holds && reverted && heldFor >= 1.45 && copyPeak == 1, "holds \(holds), reverted after \(Int(heldFor * 1000)) ms, peak \(copyPeak)")

        // Delete: the card leaves, the neighbours close the gap from the same moment, the neighbour is selected.
        selectIndex(2)
        await d.settle()
        await d.wait(150)
        let rid = model.clips[2].id, nid = model.clips[3].id
        let gap = Double(rest(2).minX), nStart = Double(rest(3).minX)
        var goneBlur = 0.0, goneScale = 1.0, goneLast = 1.0, together = false, nPop = 1.0
        var ringXs: [Double] = []
        if let gone = board.motions[rid] {
            gone.op.probe = { goneLast = $0 }
            gone.blur.probe = { goneBlur = max(goneBlur, $0) }
            gone.es.probe = { goneScale = min(goneScale, $0) }
            board.motions[nid]?.x.probe = { x in if x < nStart - 1, gone.op.v > 0.05 { together = true } }
        }
        board.motions[nid]?.pop.probe = { nPop = max(nPop, $0) }
        ring.probe = { ringXs.append(Double($0.x)) }
        let goneMotion = board.motions[rid]
        let count1 = store.count
        d.key(kVK_Delete, .command)
        let neighbourAtOnce = Double(board.currentRect(nid)?.minX ?? -1)
        let leavingAtOnce = board.leaving.count
        await d.settle()
        let ringDrift = ringXs.map { abs($0 - gap) }.max() ?? 99
        debugLog("motion: remove card 2: leaving card blur peak \(fmt(goneBlur)), scale low \(fmt(goneScale)), last opacity \(fmt(goneLast)); neighbour moved while it still showed \(together); ring drift while the neighbour slid in \(fmt(ringDrift)) pt; neighbour pop \(fmt(nPop))")
        let goneClean = goneMotion?.gone == true && goneMotion?.cell == nil && board.leaving.isEmpty
        if rm {
            check("Reduce Motion: ⌘⌫ fades the card out (0.12 s) and the neighbours jump into the gap",
                  leavingAtOnce == 1 && neighbourAtOnce == gap && goneBlur == 0 && goneScale == 1 && goneLast == 0 && goneClean,
                  "leaving \(leavingAtOnce), neighbour at \(neighbourAtOnce), blur \(goneBlur), scale \(goneScale)")
        } else {
            check("⌘⌫: the card accelerates away (fade, 0.92, 8 px blur on leave) and is put away",
                  leavingAtOnce == 1 && abs(goneBlur - 8) < 0.001 && abs(goneScale - 0.92) < 0.001 && goneLast == 0 && goneClean,
                  "leaving \(leavingAtOnce), blur \(goneBlur), scale \(goneScale), last opacity \(goneLast), clean \(goneClean)")
            check("⌘⌫: the neighbours close the gap from the same moment, so it never sits empty",
                  together && neighbourAtOnce == nStart, "together \(together), neighbour started at \(neighbourAtOnce)")
        }
        check("⌘⌫: the neighbour is selected and pops, and the ring holds still as it slides in",
              store.count == count1 - 1 && model.selectedID == nid && Double(board.currentRect(nid)?.minX ?? -1) == gap
                  && (rm ? nPop == 1 : abs(nPop - Motion.popPeak) < 0.001) && ringDrift < 0.5,
              "selected \(model.selectedIndex ?? -1), at \(board.currentRect(nid)?.minX ?? -1), pop \(nPop), ring drift \(fmt(ringDrift))")
        ring.probe = nil
        board.motions[nid]?.x.probe = nil
        board.motions[nid]?.pop.probe = nil

        // In a 2-row grid: removing the last card of the first row pulls the next row's first card up.
        d.key(kVK_UpArrow, .option)
        await d.settle()
        let cols = grid.columns
        selectIndex(cols - 1)
        await d.settle()
        let wrapID = model.clips[cols].id
        let slot = rest(cols - 1).origin
        d.key(kVK_Delete, .command)
        await d.settle()
        check("2-row grid: ⌘⌫ on the last card of row 1 pulls row 2's first card up into its slot, selected",
              rows == 2 && model.selectedID == wrapID && board.currentRect(wrapID)?.origin == slot && board.leaving.isEmpty,
              "rows \(rows), selected \(model.selectedIndex ?? -1), at \(board.currentRect(wrapID)?.origin ?? .zero), slot \(slot)")
        d.key(kVK_DownArrow, .option)
        await d.settle()

        // A copy that arrives while the panel is open, at the front: born from a blur as the others make room.
        board.scroll(to: .zero, instant: true)
        selectIndex(1)
        await d.settle()
        let keep = model.selectedID
        let front = model.clips[0].id
        let frontX = Double(rest(0).minX)
        let new = d.insertText("Copied while the panel was open.")
        let nm = board.motions[new.id]
        let bornOp = nm?.op.v ?? -1, bornBlur = nm?.blur.v ?? -1, bornScale = nm?.es.v ?? -1
        let fm = board.motions[front]
        let room = fm?.x.dest == frontX + pitch && (rm ? fm?.x.v == frontX + pitch : fm?.x.busy == true)
        await d.settle()
        let landed = nm?.op.v == 1 && nm?.blur.v == 0 && nm?.es.v == 1
        let ringOn = keep.flatMap { board.restingRect($0) }.map { ring.drawn == $0.origin } ?? false
        check(rm ? "Reduce Motion: a new copy fades in at the front and the others jump to make room"
                 : "a new copy is born at the front (20 px blur, 1.08, clear) as the others make room on settle",
              model.clips.first?.id == new.id && bornOp == 0 && room
                  && (rm ? bornBlur == 0 && bornScale == 1 : bornBlur == 20 && abs(bornScale - 1.08) < 1e-9),
              "opacity \(bornOp), blur \(bornBlur), scale \(bornScale), room \(room)")
        check("…it lands sharp, and the selection and ring stay on the same clip", landed && model.selectedID == keep && ringOn,
              "landed \(landed), same \(model.selectedID == keep), ring on it \(ringOn)")

        // Scrolled away from the front, a new copy moves nothing in view.
        board.scroll(to: CGPoint(x: 6 * pitch, y: 0), instant: true)
        await d.settle()
        let watch = model.clips[8].id
        let v0 = Double(board.viewport.minX)
        let s0 = Double(board.currentRect(watch)?.minX ?? 0) - v0
        let away = d.insertText("Copied while the row was scrolled away.")
        let v1 = Double(board.viewport.minX)
        let s1 = Double(board.currentRect(watch)?.minX ?? 0) - v1
        await d.settle()
        check("scrolled away, a new copy moves nothing in view (the row's scroll moves with the cards)",
              v1 == v0 + pitch && s1 == s0 && board.motions[away.id]?.op.v == 1 && board.motions[watch]?.busy == false,
              "scroll \(v0) → \(v1), card on screen \(s0) → \(s1)")

        // An image copy: its thumbnail loads, then is born blurred.
        board.scroll(to: .zero, instant: true)
        await d.settle()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clipnpaste self-test \(UUID().uuidString).png")
        if Self.writeTestPNG(to: url, width: 640, height: 360) {
            let image = store.insertOrBump(Clip(kind: .image, imageURL: url, pixelWidth: 640, pixelHeight: 360,
                                                sourceBundleID: "com.apple.Photos", sourceAppName: "Photos",
                                                contentHash: DemoClips.hash(url.path)))
            let tlook = board.motions[image.id]?.cell?.look
            var blurPeak = 0.0, clearLow = 1.0
            tlook?.ib.probe = { blurPeak = max(blurPeak, $0) }
            tlook?.io.probe = { clearLow = min(clearLow, $0) }
            for _ in 0..<80 {
                await d.wait(25)
                if ThumbnailStore.shared.cached(image.id) != nil, clearLow < 1, tlook?.io.busy == false, tlook?.ib.busy == false { break }
            }
            await d.settle()
            let sharp = tlook?.thumbBlur == 0 && tlook?.thumbOpacity == 1
            debugLog("motion: thumbnail blur peak \(fmt(blurPeak)) px, opacity low \(fmt(clearLow)), sharp at rest \(sharp)")
            check(rm ? "Reduce Motion: the thumbnail fades in, no blur" : "the thumbnail is born blurred (12 px → 0 on quick, with a fade) and ends sharp",
                  tlook != nil && clearLow == 0 && sharp && (rm ? blurPeak == 0 : abs(blurPeak - 12) < 0.001),
                  "look \(tlook != nil), blur peak \(blurPeak), opacity low \(clearLow), sharp \(sharp)")
            tlook?.ib.probe = nil
            tlook?.io.probe = nil
            store.remove(id: image.id)
            await d.settle()
        } else {
            check("the thumbnail check could write its test picture", false, url.path)
        }
        try? FileManager.default.removeItem(at: url)

        // At rest: no filter on any layer, every card on whole points, the ring centred on its card.
        selectIndex(1)
        await d.settle()
        var layers = 0, filtered = 0
        func walk(_ l: CALayer) {
            layers += 1
            if let f = l.filters, !f.isEmpty { filtered += 1 }
            l.sublayers?.forEach(walk)
        }
        if let l = content.layer { walk(l) }
        let shown = content.documentView.subviews.compactMap { $0 as? CardCell }.filter { !$0.isHidden }
        let offGrid = shown.filter { $0.frame.minX != $0.frame.minX.rounded() || $0.frame.minY != $0.frame.minY.rounded() }.count
        let selRect = model.selectedID.flatMap { board.currentRect($0) } ?? .zero
        let centred = abs(ring.view.frame.midX - selRect.midX) < 0.01 && abs(ring.view.frame.midY - selRect.midY) < 0.01 && !ring.view.isHidden
        let idle = MotionClock.shared.isIdle
        check("at rest: nothing moves, no filter on any of the panel's \(layers) layers, \(shown.count) cards on whole points, the ring centred on its card",
              idle && filtered == 0 && offGrid == 0 && centred, "idle \(idle), \(filtered) with filters, \(offGrid) off the grid, ring centred \(centred)")
    }

    /// A small landscape picture for the thumbnail check.
    static func writeTestPNG(to url: URL, width w: Int, height h: Int) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(srgbRed: 0.23, green: 0.25, blue: 0.48, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.70, blue: 0.42, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 3 / 5, y: h / 3, width: h / 3, height: h / 3))
        ctx.setFillColor(CGColor(srgbRed: 0.17, green: 0.14, blue: 0.25, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 4))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: Scenes

    /// `--scene` states for screenshots of the card motion (pair with `--slow-motion N`): card-slide,
    /// card-hold (a held →), card-press, card-hover, card-copy, card-remove, card-insert, card-thumb,
    /// and card-remove-end (the last card removed with the row scrolled to its end: the view eases
    /// back, logged frame by frame). Returns false for a name it doesn't know.
    func showCardScene(_ name: String) async -> Bool {
        let d = Driver(self)
        guard name.hasPrefix("card-") else { return false }
        selectIndex(1)
        await d.wait(600)
        switch name {
        case "card-slide":
            d.key(kVK_RightArrow)
        case "card-hold":
            for _ in 0..<4 { d.key(kVK_RightArrow); await d.wait(40) }
        case "card-press":
            d.mouse(.leftMouseDown, d.cardPoint(2))
        case "card-hover":
            model.setHover(model.clips[2].id, .remove)
        case "card-copy":
            copyInterceptor = { _ in }
            d.key(kVK_ANSI_C, .command, "c")
        case "card-remove":
            d.key(kVK_Delete, .command)
        case "card-insert":
            _ = d.insertText("Copied while the panel was open.")
        case "card-remove-end":
            d.key(kVK_RightArrow, .command)
            await d.settle()
            let before = board.viewport.minX
            var seen: [CGFloat] = []
            d.key(kVK_Delete, .command)
            for _ in 0..<40 {
                await d.frames(1)
                seen.append(board.viewport.minX)
            }
            let steps = zip(seen, seen.dropFirst()).map { $0 - $1 }
            debugLog("scene card-remove-end: scroll \(before) → \(board.viewport.minX) (max \(board.maxScroll.x)), document \(content.documentView.frame.width) for content \(board.contentSize.width); per-frame steps \(steps.map { Int($0.rounded()) }), largest \(steps.max() ?? 0)")
        case "card-idle":
            // With `--empty` too: nothing may keep the display link running at rest.
            await d.wait(1000)
            debugLog("scene card-idle: \(model.clips.count) clips, ring shown \(!board.ring.view.isHidden), motion idle \(MotionClock.shared.isIdle)")
        case "card-thumb":
            // Kept in the demo folder, which is removed when the app quits.
            try? FileManager.default.createDirectory(at: DemoExtras.folder, withIntermediateDirectories: true)
            let url = DemoExtras.folder.appendingPathComponent("scene.png")
            if Self.writeTestPNG(to: url, width: 640, height: 360) {
                store.insertOrBump(Clip(kind: .image, imageURL: url, pixelWidth: 640, pixelHeight: 360,
                                        sourceBundleID: "com.apple.Photos", sourceAppName: "Photos",
                                        contentHash: DemoClips.hash(url.path)))
            }
        default:
            return false
        }
        debugLog("scene \(name) started")
        await snapshots(name)
        return true
    }

    /// `--snap-ms 120,400 --snap-dir DIR` with a card scene: renders the panel's own layers to
    /// PNGs that many ms after the scene starts. Needs no screen-recording permission; layer
    /// filters (the blurs) and the glass don't show in them.
    private func snapshots(_ name: String) async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        guard let times = value("--snap-ms")?.split(separator: ",").compactMap({ Int($0) }), let dir = value("--snap-dir") else { return }
        let start = CACurrentMediaTime()
        for ms in times.sorted() {
            let left = Double(ms) / 1000 - (CACurrentMediaTime() - start)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            // What is in view of the scroll document: each card and the ring composited by hand at
            // its frame, scale and opacity, back to front (rendering the whole tree misplaces them).
            let view = board.viewport
            let size = view.size, scale: CGFloat = 2
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.scaleBy(x: scale, y: scale)
            panel.effectiveAppearance.performAsCurrentDrawingAppearance {
                ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            }
            ctx.fill(CGRect(origin: .zero, size: size))
            // The views are flipped (y down); the bitmap is y up.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            let parts = content.documentView.subviews
                .filter { !$0.isHidden && ($0 is CardCell || $0 is RingView) && $0.frame.intersects(view) }
                .sorted { ($0.layer?.zPosition ?? 0) < ($1.layer?.zPosition ?? 0) }
            for v in parts {
                guard let l = v.layer else { continue }
                let f = v.frame, s = l.transform.m11
                ctx.saveGState()
                ctx.translateBy(x: f.midX - view.minX, y: f.midY - view.minY)
                ctx.scaleBy(x: s, y: s)
                ctx.translateBy(x: -f.width / 2, y: -f.height / 2)
                ctx.setAlpha(CGFloat(l.opacity))
                l.render(in: ctx)
                ctx.restoreGState()
            }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(ms).png")
            if let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                debugLog("snapshot \(url.lastPathComponent) at \(Int((CACurrentMediaTime() - start) * 1000)) ms")
            }
        }
    }
}

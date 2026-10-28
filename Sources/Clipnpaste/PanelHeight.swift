import AppKit
import ClipnpasteCore

/// The glass's height and the strip: the only things that change the glass's size. The window is
/// sized once before a resize starts and fitted once after it settles, never per frame; in
/// between only the glass view's frame changes.
@MainActor
final class GlassMotion: MotionTarget {
    unowned let controller: PanelController
    /// Glass height in points.
    let h: Anim
    /// The cards and the top bar's sides: 1 normally, 0 in the strip (they blur out as they fade).
    let fade: Anim
    /// 0 → 1 moves the pill 8 pt down, to the middle of the strip.
    let shift: Anim

    init(controller: PanelController) {
        self.controller = controller
        h = Anim(180, owner: nil, eps: 0.05)
        fade = Anim(1, owner: nil, eps: 0.002)
        shift = Anim(0, owner: nil, eps: 0.002)
        for a in [h, fade, shift] { a.owner = self }
    }

    func render() { controller.renderGlass() }
}

struct PillDrag {
    let y0: CGFloat
    let h0: Double
    var raw: Double
    var velocity = VelocityTracker()
    /// −1 at the lower limit, 1 at the upper one, 0 between.
    var limit = 0
}

struct HistoryState {
    var loaded: [Clip] = []
    var hasMore = false
    var loading = false
    var token = 0
}

extension PanelController {
    // MARK: Glass

    var targetHeight: Double {
        let g = model.geometry.grid
        if strip == .strip { return Double(PanelGrid.stripHeight) }
        return Double(model.mode == .history ? g.maxHeight : g.height(rows: rows))
    }

    func renderGlass() {
        let g = model.geometry
        let inset = CGFloat(PanelGeometry.inset)
        let scale = screen?.backingScaleFactor ?? 2
        let h = max(pixelSnap(glass.h.v, scale: scale), 1)
        let f = NSRect(x: inset, y: inset, width: CGFloat(g.width), height: h)
        if surface.frame != f {
            surface.frame = f
            // A new frame must not drop the rise's transform.
            renderRise(sample: false)
        }
        let fade = min(max(glass.fade.v, 0), 1)
        if let layer = content.cardsArea.layer {
            layer.opacity = Float(fade)
            LayerLook.blur(layer, fade < 0.995 ? (1 - fade) * 10 : 0)
        }
        content.topBar.setSidesOpacity(fade)
        content.topBar.pill.shiftY = CGFloat(glass.shift.v * 8)
        if pill == nil, drag == nil { updatePassThrough() }
    }

    // MARK: Window

    /// The window from the bottom of the visible frame up to the glass top plus 40 pt of shadow.
    func windowFrame(glassHeight: Double) -> NSRect {
        guard let screen else { return panel.frame }
        let vf = screen.visibleFrame
        let h = CGFloat(PanelGeometry.inset) + CGFloat(glassHeight.rounded(.up)) + CGFloat(PanelGeometry.shadowRoom)
        return NSRect(x: vf.minX.rounded(.down), y: vf.minY.rounded(.down), width: CGFloat(Int(vf.width)), height: h)
    }

    /// Once, before the glass grows: room for 3 rows plus the rubber band past them.
    func growWindow() {
        guard let screen else { return }
        let vf = screen.visibleFrame
        let y = vf.minY.rounded(.down)
        let room = CGFloat(PanelGeometry.inset + model.geometry.grid.maxHeight + PanelGeometry.shadowRoom) + CGFloat(RubberBand.reach)
        let f = NSRect(x: vf.minX.rounded(.down), y: y, width: CGFloat(Int(vf.width)), height: min(room, screen.frame.maxY - y))
        if panel.frame != f { panel.setFrame(f, display: false) }
    }

    /// Once, after the glass settles: the window shrinks back around it.
    func fitWindow() {
        guard pill == nil, !glass.h.busy else { return }
        if drag != nil, strip == .full { return }
        let f = windowFrame(glassHeight: glass.h.v)
        if panel.frame != f { panel.setFrame(f, display: false) }
        updatePassThrough()
    }

    // MARK: Chrome

    var pillEnabled: Bool { model.geometry.canGrow && model.mode != .history && !model.clips.isEmpty }
    var pillVisible: Bool { (pillEnabled && strip == .full) || strip == .strip }
    var historyEnabled: Bool { model.totalCount > 0 }

    func updateChrome() {
        let bar = content.topBar
        bar.pill.isHidden = !pillVisible
        bar.history.enabled = historyEnabled
        bar.history.selected = model.mode == .history
        if !historyEnabled {
            bar.history.hovered = false
            if model.focus == .history { model.focus = .card }
        }
        bar.history.focused = model.focus == .history
        let empty = model.clips.isEmpty
        if content.emptyHost.isHidden == empty {
            content.emptyHost.isHidden = !empty
            // The last clip removed while open: the first-use message is born blurred.
            if empty, phase == .open { content.emptyFx.born(blur: 20, scale: 1.06) }
        }
    }

    // MARK: Rows

    /// Rows the panel opens at (Settings › Panel › Height), up to what fits the screen.
    func savedRows() -> Int {
        min(max(prefs.panelRows, 1), model.geometry.grid.maxRows)
    }

    /// The pill and ⌥↑ / ⌥↓ set the height Settings shows. A screen too short for the setting
    /// leaves it alone.
    private func saveRows() {
        if savedRows() != rows { prefs.panelRows = rows }
    }

    /// The height changed in Settings: an open panel moves to it on `settle`, as ⌥↑ / ⌥↓ do; a
    /// closed one, or one in history or mid-gesture, opens at it next time.
    func applyRowsSetting() {
        let k = savedRows()
        guard k != rows, isOpen, model.mode != .history else { return }
        stepRows(k - rows)
    }

    /// The viewport of the scroll area for a glass height, with the scroll folded out.
    func viewAt(height h: Double) -> CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(model.geometry.width), height: max(CGFloat(h) - CGFloat(PanelGrid.scrollTop), 0))
    }

    /// The viewport that shows `r` whole rows.
    func viewAt(rows r: Int) -> CGRect {
        let g = model.geometry.grid
        return CGRect(x: 0, y: 0, width: CGFloat(model.geometry.width),
                      height: CGFloat(PanelGrid.contentTop + r * g.pitchY - g.gap + 1))
    }

    /// A row boundary was crossed: the row becomes a grid at 2 rows (newest top-left, same columns),
    /// and the row that came into view is born blurred.
    func setRowsShown(_ k: Int) {
        let newMode: PanelMode = k > 1 ? .grid : .row
        if newMode != model.mode, model.mode != .history {
            let before = model.mode == .grid ? viewAt(rows: board.rowsShown) : viewAt(height: glass.h.v)
            board.rebaseScroll()
            model.mode = newMode
            layoutBoard(.mode(before: before, after: viewAt(rows: k)))
            MotionClock.shared.flush()
        }
        board.rowsShown = k
        board.applyConceal()
        updateChrome()
    }

    // MARK: Pill

    static func resizeCursor(_ d: NSCursor.FrameResizeDirection.Set) -> NSCursor {
        NSCursor.frameResize(position: .top, directions: d)
    }

    private func pillScreenY(_ e: NSEvent) -> CGFloat { panel.convertPoint(toScreen: e.locationInWindow).y }

    private func eventTime(_ e: NSEvent) -> Double {
        e.timestamp > 0 ? e.timestamp : ProcessInfo.processInfo.systemUptime
    }

    func pillDown(_ e: NSEvent) {
        growWindow()
        if model.mode == .grid, board.viewport.minY != 0 { board.scroll(to: .zero, instant: true) }
        let y = pillScreenY(e)
        var st = PillDrag(y0: y, h0: glass.h.v, raw: glass.h.v)
        st.velocity.add(time: eventTime(e), x: 0, y: Double(y))
        pill = st
        glass.h.stop()
        board.concealOn = true
        board.rowsShown = model.mode == .grid ? rows : 1
        content.topBar.pill.setLook(.pressed)
        Self.resizeCursor(.all).set()
        panel.ignoresMouseEvents = false
    }

    /// The height follows the pointer 1:1 from the grab point; past a limit it rubber-bands.
    func pillMove(_ e: NSEvent) {
        guard var st = pill else { return }
        let y = pillScreenY(e)
        st.velocity.add(time: eventTime(e), x: 0, y: Double(y))
        let g = model.geometry.grid
        let lo = Double(g.minHeight), hi = Double(g.maxHeight)
        let raw = st.h0 + Double(y - st.y0)
        st.raw = raw
        let h = Motion.reduce ? min(max(raw, lo), hi) : RubberBand.apply(raw, min: lo, max: hi)
        let limit = raw >= hi ? 1 : (raw <= lo ? -1 : 0)
        var tick = limit != 0 && limit != st.limit
        st.limit = limit
        pill = st
        glass.h.set(h)
        let k = g.rowsShown(height: h)
        if k != board.rowsShown {
            setRowsShown(k)
            tick = true
        }
        if tick { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        // Up only at one row, down only at three.
        let dirs: NSCursor.FrameResizeDirection.Set = h <= lo + 0.5 ? .outward : (h >= hi - 0.5 ? .inward : .all)
        Self.resizeCursor(dirs).set()
    }

    /// Released: the height is projected forward by 0.12 s of the release speed and snaps to the
    /// nearest whole row on `arrive`, starting with the drag's speed, no overshoot. From a
    /// rubber-banded height it returns to the limit on `quick`.
    func pillUp(_ e: NSEvent?, cancel: Bool = false) {
        guard let st = pill else { return }
        pill = nil
        var over = false
        if let e, case .pill = hit(e.locationInWindow) { over = true }
        pillHovered = over
        content.topBar.pill.setLook(over ? .hover : .rest)
        (over ? Self.resizeCursor(.all) : NSCursor.arrow).set()
        let g = model.geometry.grid
        let lo = Double(g.minHeight), hi = Double(g.maxHeight)
        let v = cancel ? 0 : st.velocity.velocity(at: e.map(eventTime) ?? ProcessInfo.processInfo.systemUptime).y
        var k: Int
        var duration = Motion.arrive
        var velocity: Double? = v
        if st.raw > hi || st.raw < lo {
            k = st.raw > hi ? g.maxRows : 1
            duration = Motion.quick
            velocity = 0
        } else {
            k = g.snapRows(height: glass.h.v, velocity: v)
        }
        k = min(max(k, 1), g.maxRows)
        rows = k
        saveRows()
        setRowsShown(k)
        debugLog("pill: released at \(String(format: "%.1f", glass.h.v)) pt, speed \(Int(v)) pt/s → \(k) rows (\(g.height(rows: k)) pt)")
        glass.h.move(to: Double(g.height(rows: k)), duration: duration, velocity: velocity) { [weak self] in
            self?.pillSettled()
        }
    }

    func pillSettled() {
        guard pill == nil else { return }
        board.concealOn = false
        board.applyConceal()
        fitWindow()
    }

    /// ⌥↑ / ⌥↓: one row more or fewer, on `settle`.
    func stepRows(_ d: Int) {
        guard isOpen, pillEnabled, pill == nil, drag == nil, strip == .full else { return }
        let g = model.geometry.grid
        let k = min(max(rows + d, 1), g.maxRows)
        guard k != rows else { return }
        growWindow()
        if model.mode == .grid, board.viewport.minY != 0 { board.scroll(to: .zero, instant: true) }
        board.concealOn = true
        board.rowsShown = model.mode == .grid ? rows : 1
        rows = k
        saveRows()
        setRowsShown(k)
        glass.h.move(to: Double(g.height(rows: k)), duration: Motion.settle) { [weak self] in
            self?.pillSettled()
        }
    }

    // MARK: History

    func toggleHistory() {
        guard isOpen, drag == nil, pill == nil, strip == .full else { return }
        model.mode == .history ? leaveHistory() : enterHistory()
    }

    /// The panel grows to its tallest on `arrive`; the cards that stay in view are carried to
    /// their place under "Today", and the rest are born blurred 20 ms apart per row.
    func enterHistory() {
        guard historyEnabled, model.mode != .history else { return }
        Diagnostics.shared.begin(.history)
        let before = viewAt(height: glass.h.v)
        board.rebaseScroll()
        history = HistoryState(token: history.token + 1)
        history.loaded = store.newestByDate(Self.historyPage)
        history.hasMore = history.loaded.count < store.count
        model.mode = .history
        model.totalCount = store.count
        model.clips = history.loaded
        if !model.clips.contains(where: { $0.id == model.selectedID }) { model.selectedID = model.clips.first?.id }
        growWindow()
        let h = Double(model.geometry.grid.maxHeight)
        layoutBoard(.mode(before: before, after: viewAt(height: h)))
        MotionClock.shared.flush()
        glass.h.move(to: h, duration: Motion.arrive) { [weak self] in self?.fitWindow() }
        updateChrome()
        scrollToSelection()
        historyScrolled()
    }

    /// Back to the row or grid: the rows below blur out on `leave`, the height returns on `arrive`.
    func leaveHistory() {
        guard model.mode == .history else { return }
        Diagnostics.shared.begin(.history)
        let before = viewAt(height: glass.h.v)
        board.rebaseScroll()
        history = HistoryState(token: history.token + 1)
        model.mode = rows > 1 ? .grid : .row
        model.clips = store.ordered(Self.clipLimit)
        if !model.clips.contains(where: { $0.id == model.selectedID }) { model.selectedID = model.clips.first?.id }
        let h = targetHeight
        layoutBoard(.mode(before: before, after: viewAt(height: h)))
        MotionClock.shared.flush()
        glass.h.move(to: h, duration: Motion.arrive) { [weak self] in self?.fitWindow() }
        updateChrome()
        scrollToSelection()
    }

    /// Pages older clips in as the history nears its end.
    func historyScrolled() {
        guard model.mode == .history, history.hasMore, !history.loading, let last = history.loaded.last else { return }
        let v = board.viewport
        let viewH = max(v.height, CGFloat(glass.h.dest) - CGFloat(PanelGrid.scrollTop))
        guard v.minY + viewH > board.contentSize.height - viewH * 1.5 else { return }
        history.loading = true
        let token = history.token
        let before = last.createdAt
        Task { [weak self] in
            guard let self else { return }
            let page = await self.store.page(before: before, limit: Self.historyPage)
            guard self.model.mode == .history, self.history.token == token else { return }
            let known = Set(self.history.loaded.map(\.id))
            self.history.loaded += page.filter { !known.contains($0.id) }
            self.history.hasMore = page.count >= Self.historyPage && self.history.loaded.count < self.store.count
            self.history.loading = false
            self.model.clips = self.history.loaded
            debugLog("history: paged \(page.count) older clips in, \(self.history.loaded.count) of \(self.store.count) loaded")
            self.layoutBoard(.reflow)
            self.historyScrolled()
        }
    }

    // MARK: Strip

    /// The dragged card left the panel: the panel shrinks to the strip, slides away or stays,
    /// as Settings › Motion › Panel while dragging out says.
    func cardLeftPanel() {
        switch prefs.dragOut {
        case .strip: enterStrip()
        case .slide: slideAway()
        case .stay: break
        }
    }

    /// Back to full height, from the strip or from sliding away.
    func restorePanel() {
        switch strip {
        case .strip: exitStrip()
        case .slid: slideBack()
        case .full: break
        }
    }

    /// "Slide away": the whole panel leaves as it does on close, accelerating down by its height
    /// + 40 pt on `leave` over 180 ms, so the screen is free for the drop. Reduce Motion: a 120 ms fade.
    func slideAway() {
        guard strip == .full else { return }
        strip = .slid
        if Motion.reduce {
            rise.op.tween(to: 0, ms: 120)
        } else {
            rise.y.tween(to: glass.h.v + Self.riseExtra, ms: 180, ease: Motion.leave, carry: true)
        }
        updateChrome()
    }

    /// The card came back over the bottom edge: the panel rises back on `arrive`, as when it opens.
    func slideBack() {
        guard strip == .slid else { return }
        strip = .full
        if Motion.reduce {
            rise.op.tween(to: 1, ms: 120)
        } else {
            rise.y.spring(to: 0, duration: Motion.arrive)
        }
        updateChrome()
    }

    /// The dragged card crossed the panel's top edge: the panel shrinks to a 40 pt glass strip
    /// holding the pill, and the cards accelerate out with a blur.
    func enterStrip() {
        guard strip == .full else { return }
        strip = .strip
        let s = Double(PanelGrid.stripHeight)
        if Motion.reduce {
            glass.h.set(s)
            glass.fade.tween(to: 0, ms: 120)
            glass.shift.set(1)
            fitWindow()
        } else {
            glass.h.spring(to: s, duration: Motion.settle) { [weak self] in self?.fitWindow() }
            glass.fade.tween(to: 0, ms: 160, ease: Motion.leave)
            glass.shift.spring(to: 1, duration: Motion.settle)
        }
        updateChrome()
    }

    /// Back over the strip: the panel grows back to full height and the cards are born from a blur.
    func exitStrip() {
        guard strip == .strip else { return }
        strip = .full
        growWindow()
        let h = targetHeight
        if Motion.reduce {
            glass.h.set(h)
            glass.fade.tween(to: 1, ms: 120)
            glass.shift.set(0)
            fitWindow()
        } else {
            glass.h.spring(to: h, duration: Motion.arrive) { [weak self] in self?.fitWindow() }
            glass.fade.spring(to: 1, duration: Motion.quick)
            glass.shift.spring(to: 0, duration: Motion.arrive)
        }
        updateChrome()
    }
}

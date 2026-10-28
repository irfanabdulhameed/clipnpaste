import AppKit
import ClipnpasteCore

/// One card's motion: where it sits and how it looks, each value on its own spring or keys.
@MainActor
final class CardMotion: MotionTarget {
    let id: UUID
    unowned let board: Board
    let x: Anim, y: Anim
    /// Entrance rise, opacity, blur (pt) and entrance scale.
    let dy: Anim, op: Anim, blur: Anim, es: Anim
    /// The 1.08 selection pop and the 0.97 press dip. The card is drawn at es × pop × dip.
    let pop: Anim, dip: Anim
    var clip: Clip
    var placed = false
    /// Hidden while the pill is dragged until its row is uncovered.
    var concealed = false
    var hiding = false
    /// Removed: accelerating away while the others close the gap.
    var leaving = false
    /// Off the board: it draws nothing more.
    var gone = false
    var gen = 0
    var row = 0, col = 0
    weak var cell: CardCell?

    init(clip: Clip, board: Board) {
        id = clip.id
        self.clip = clip
        self.board = board
        x = Anim(0, owner: nil, eps: 0.05)
        y = Anim(0, owner: nil, eps: 0.05)
        dy = Anim(0, owner: nil, eps: 0.05)
        op = Anim(1, owner: nil, eps: 0.002)
        blur = Anim(0, owner: nil, eps: 0.05)
        es = Anim(1, owner: nil, eps: 0.0005)
        pop = Anim(1, owner: nil, eps: 0.0005)
        dip = Anim(1, owner: nil, eps: 0.0005)
        for a in anims { a.owner = self }
    }

    var anims: [Anim] { [x, y, dy, op, blur, es, pop, dip] }
    var busy: Bool { anims.contains { $0.busy } }
    var scale: Double { es.v * pop.v * dip.v }
    /// The rect it is drawn at now, in the scroll content.
    var rect: CGRect {
        CGRect(x: x.v, y: y.v + dy.v, width: Double(board.grid.cardWidth), height: Double(board.grid.cardHeight))
    }

    func render() { board.render(self) }
}

/// The selection ring: one accent outline, 2.5 pt (3.5 with Increase Contrast), 2 pt outside the
/// card. It is drawn at its card plus an offset; when the selection moves, the offset starts at
/// the distance from the new card and springs to 0 (bounce 0), so the ring slides across and then
/// rides its card: position, entrance rise, pop, dip, fade and blur.
@MainActor
final class RingMotion: MotionTarget {
    unowned let board: Board
    let view = RingView()
    /// The ring's offset from its card; 0 at rest.
    let ox: Anim, oy: Anim
    /// The card it was last drawn around, and where (the card rect's top-left); nil while hidden.
    var cardID: UUID?
    var drawn: CGPoint?
    /// Every drawn position, for the motion log and the self-test.
    var probe: ((CGPoint) -> Void)?

    init(board: Board) {
        self.board = board
        ox = Anim(0, owner: nil, eps: 0.05)
        oy = Anim(0, owner: nil, eps: 0.05)
        ox.owner = self
        oy.owner = self
    }

    var busy: Bool { ox.busy || oy.busy }

    func render() { board.renderRing() }
}

/// Draws the ring: a layer border, so it costs nothing at rest.
@MainActor
final class RingView: NSView {
    private var lastBlur: Double = 0
    private var lineWidth: CGFloat = -1

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        isHidden = true
        recolor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    /// The accent colour, read again on every open in case it changed.
    func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    /// Around a card whose unscaled rect is `card`, scaled with the card about its centre.
    func place(card: CGRect, width w: CGFloat, scale: Double, opacity: Double, blur: Double) {
        let out = 2 + w
        let f = card.insetBy(dx: -out, dy: -out)
        if frame != f { frame = f }
        guard let layer else { return }
        // Above every card.
        if layer.zPosition != 10 { layer.zPosition = 10 }
        if lineWidth != w {
            lineWidth = w
            layer.borderWidth = w
            layer.cornerRadius = 14 + w
            layer.cornerCurve = .continuous
        }
        layer.transform = CardCell.scale(scale, about: CGPoint(x: f.width / 2, y: f.height / 2), anchor: layer.anchorPoint, size: f.size)
        let o = min(max(opacity, 0), 1)
        layer.opacity = Float(o)
        setBlur(blur)
        let hide = o <= 0.001
        if isHidden != hide { isHidden = hide }
    }

    private func setBlur(_ r: Double) {
        guard abs(r - lastBlur) > 0.01 || (r <= 0.05) != (lastBlur <= 0.05) else { return }
        lastBlur = r
        LayerLook.blur(layer, r)
    }
}

/// A day header's motion in history.
@MainActor
final class HeaderMotion: MotionTarget {
    let view = DayHeaderView()
    unowned let board: Board
    let y: Anim, op: Anim, blur: Anim
    var text = ""

    init(board: Board) {
        self.board = board
        y = Anim(0, owner: nil, eps: 0.05)
        op = Anim(1, owner: nil, eps: 0.002)
        blur = Anim(0, owner: nil, eps: 0.05)
        for a in [y, op, blur] { a.owner = self }
    }

    func render() {
        view.place(x: CGFloat(board.grid.sidePadding), y: y.v, width: CGFloat(board.grid.columns * board.grid.pitchX),
                   opacity: op.v, blur: blur.v)
    }
}

/// Programmatic scrolling (to the selection, auto-scroll while dragging) on a spring.
@MainActor
final class ScrollMotion: MotionTarget {
    unowned let board: Board
    let sx: Anim, sy: Anim

    init(board: Board) {
        self.board = board
        sx = Anim(0, owner: nil, eps: 0.1)
        sy = Anim(0, owner: nil, eps: 0.1)
        sx.owner = self
        sy.owner = self
    }

    func render() {
        board.scrollNow(to: CGPoint(x: sx.v, y: sy.v))
        if !sx.busy, !sy.busy { board.scrollSettled() }
    }
}

/// The cards in the panel: their layout in row, grid and history mode, their motion, and the
/// cells that draw the ones in view (cells exist only for visible cards, recycled as you scroll).
@MainActor
final class Board {
    enum Kind {
        /// Everything jumps to its place.
        case instant
        /// Everything slides to its new place on `settle` (reorder, remove, insert). A removed card
        /// leaves on `leave`; a copy that arrived while the panel is open is born from a blur at
        /// the front (scrolled away from the front, nothing visible moves).
        case reflow
        /// A mode change: cards in view before and after are carried on `settle`, cards arriving
        /// are born blurred 20 ms apart per row, cards leaving blur out on `leave`. The rects are
        /// the viewport before and after, with the scroll offset already folded into positions.
        case mode(before: CGRect, after: CGRect)
    }

    /// Whether a selection change pops the card: normally unless an arrow key is held, never
    /// (a click that pastes), or always (the neighbour selected after a remove).
    enum Pop { case normal, none, force }

    let model: PanelModel
    let content: PanelContentView
    var scrollView: NSScrollView { content.scrollView }
    var document: CardsDocumentView { content.documentView }

    private(set) var mode: PanelMode = .row
    private(set) var order: [Clip] = []
    private(set) var origins: [UUID: PanelGrid.Origin] = [:]
    /// Card ids per visual row, for ↑ and ↓.
    private(set) var rows: [[UUID]] = []
    private(set) var contentSize = CGSize.zero
    private(set) var motions: [UUID: CardMotion] = [:]
    /// Removed cards still on their way out.
    private(set) var leaving: [CardMotion] = []
    private var headers: [Date: HeaderMotion] = [:]
    private var cells: [UUID: CardCell] = [:]
    private var pool: [CardCell] = []
    private var placeholders: [PlaceholderCardView] = []
    private(set) var placeholderRow = false
    private var generation = 0
    private(set) lazy var scroller = ScrollMotion(board: self)
    private(set) lazy var ring = RingMotion(board: self)
    private var lastSelection: CFTimeInterval = 0

    /// While the pill is dragged, rows past `rowsShown` stay hidden until their boundary is crossed.
    var concealOn = false
    var rowsShown = 1
    /// The lifted card: drawn at 35% where it will land, at its full size.
    var ghostID: UUID? {
        didSet {
            if let o = oldValue { motions[o].map(render) }
            if let g = ghostID, let m = motions[g] {
                m.dip.set(1)
                render(m)
            }
        }
    }
    /// Called after every scroll, by the user or by code.
    var onScroll: (() -> Void)?

    var grid: PanelGrid { model.geometry.grid }
    var viewport: CGRect { scrollView.contentView.bounds }
    var cardSize: CGSize { CGSize(width: grid.cardWidth, height: grid.cardHeight) }
    /// The panel is on screen, so changes animate.
    var isLive: Bool { document.window?.isVisible == true }

    init(model: PanelModel, content: PanelContentView) {
        self.model = model
        self.content = content
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
        document.addSubview(ring.view)
        model.onHoverChange = { [weak self] old, new in self?.hoverChanged(from: old, to: new) }
        model.onPressChange = { [weak self] old, new in self?.pressChanged(from: old, to: new) }
        // A few cells ready before the first open.
        for _ in 0..<12 { pool.append(CardCell(model: model)) }
    }

    // MARK: Layout

    /// Lays `clips` out for `mode` and moves every card to its place as `kind` says.
    func layout(_ clips: [Clip], mode newMode: PanelMode, kind requested: Kind, placeholders wantPlaceholders: Bool = false) {
        var kind = requested
        let live = isLive
        // A copy that arrived while the panel is open: the new cards at the front are born from a
        // blur while the others make room. Scrolled away from the front, the cards move at once
        // and the row's scroll moves with them, so nothing visible moves.
        var arrivals = 0
        var keepStill = 0.0
        if case .reflow = kind, live, newMode == mode {
            arrivals = clips.prefix { motions[$0.id] == nil }.count
            if arrivals > 0, !atFront {
                kind = .instant
                if newMode == .row { keepStill = Double(arrivals * grid.pitchX) }
                arrivals = 0
            }
        }
        if case .instant = requested { settleCardMotion() }
        mode = newMode
        order = clips
        generation += 1
        let gen = generation
        let rm = Motion.reduce

        // Positions.
        var pos: [UUID: PanelGrid.Origin] = [:]
        var rowList: [[UUID]] = []
        var sections: [HistoryLayout.Section] = []
        var size = CGSize.zero
        let w = CGFloat(model.geometry.width)
        switch newMode {
        case .row:
            for (i, c) in clips.enumerated() { pos[c.id] = grid.rowOrigin(i) }
            rowList = [clips.map(\.id)]
            size = CGSize(width: max(CGFloat(grid.rowContentWidth(count: clips.count)), w),
                          height: CGFloat(PanelGrid.contentTop + grid.cardHeight + CardLayout.bottomPadding))
        case .grid:
            for (i, c) in clips.enumerated() {
                let o = grid.gridOrigin(i)
                pos[c.id] = o
                if o.row >= rowList.count { rowList.append([]) }
                rowList[o.row].append(c.id)
            }
            size = CGSize(width: w, height: CGFloat(grid.gridContentHeight(count: clips.count)))
        case .history:
            let l = HistoryLayout(dates: clips.map(\.createdAt), grid: grid, now: model.now)
            for (i, c) in clips.enumerated() { pos[c.id] = l.origins[i] }
            rowList = l.rows.map { $0.map { clips[$0].id } }
            sections = l.sections
            var h = l.contentHeight
            if wantPlaceholders { h = l.endY + PanelGrid.headerHeight + grid.cardHeight + CardLayout.bottomPadding }
            size = CGSize(width: w, height: CGFloat(h))
            placeholderTop = l.endY + PanelGrid.headerHeight
        }
        origins = pos
        rows = rowList
        contentSize = size
        placeholderRow = newMode == .history && wantPlaceholders
        var easeBack = false
        if case .reflow = kind { easeBack = live }
        sizeDocument(easeBack: easeBack)

        // Cards.
        var firstRow = Int.max
        if case .mode(_, let after) = kind {
            for o in pos.values where visible(o, in: after) { firstRow = min(firstRow, o.row) }
        }
        if firstRow == Int.max { firstRow = 0 }
        var keep = Set<UUID>()
        for (i, c) in clips.enumerated() {
            guard let p = pos[c.id] else { continue }
            keep.insert(c.id)
            let m = motion(for: c)
            m.clip = c
            if let cell = m.cell, cell.clipID == c.id { cell.show(c) }
            m.row = p.row
            m.col = p.col
            m.gen = gen
            let px = Double(p.x), py = Double(p.y)
            if !m.placed {
                m.x.set(px); m.y.set(py)
                m.placed = true
                // Inserted: born blurred (20 → 0 px, 1.08 → 1, fade) on `settle` 40 ms after the
                // others start making room, so it lands as the gap opens.
                if i < arrivals { born(m, blur: 20, delay: 40, scale: 1.08) }
                continue
            }
            switch kind {
            case .instant:
                m.x.set(px); m.y.set(py)
            case .reflow:
                if rm { m.x.set(px); m.y.set(py) } else { m.x.spring(to: px, duration: Motion.settle); m.y.spring(to: py, duration: Motion.settle) }
            case .mode(let before, let after):
                let wasShown = !m.concealed && m.op.v > 0.05 && before.intersects(m.rect.insetBy(dx: 1, dy: 1))
                let isShown = visible(p, in: after)
                if wasShown && isShown {
                    if rm { m.x.set(px); m.y.set(py) } else { m.x.spring(to: px, duration: Motion.settle); m.y.spring(to: py, duration: Motion.settle) }
                } else if isShown {
                    m.x.set(px); m.y.set(py)
                    m.concealed = false
                    m.hiding = false
                    born(m, blur: 12, delay: 20 * Double(p.row - firstRow))
                } else if wasShown {
                    if rm {
                        m.x.set(px); m.y.set(py)
                    } else {
                        m.x.stop(); m.y.stop()
                        fadeOut(m) { [weak m] in
                            guard let m, m.gen == gen else { return }
                            m.x.set(px); m.y.set(py); m.op.set(1); m.blur.set(0)
                        }
                    }
                } else {
                    m.x.set(px); m.y.set(py)
                }
            }
        }
        for (id, m) in motions where !keep.contains(id) {
            motions[id] = nil
            if case .reflow = kind, live, m.cell != nil, viewport.intersects(m.rect) { leave(m) } else { drop(m) }
        }
        if keepStill != 0 {
            if scroller.sx.busy {
                scroller.sx.shift(by: keepStill)
            } else {
                scrollNow(to: CGPoint(x: viewport.minX + CGFloat(keepStill), y: viewport.minY))
            }
            ring.drawn = ring.drawn.map { CGPoint(x: $0.x + CGFloat(keepStill), y: $0.y) }
        }
        layoutHeaders(sections, kind: kind, firstRow: firstRow)
        layoutPlaceholders()
        updateCells()
        MotionClock.shared.markDirty(ring)
    }

    private var placeholderTop = 0

    /// At (or near) the start of the row or grid, where a new copy shows up.
    private var atFront: Bool {
        let d = scrollDestination
        return mode == .row ? d.x < CGFloat(grid.cardWidth) / 2 : d.y < CGFloat(grid.cardHeight) / 2
    }

    private func visible(_ o: PanelGrid.Origin, in r: CGRect) -> Bool {
        CGRect(x: o.x, y: o.y, width: grid.cardWidth, height: grid.cardHeight).insetBy(dx: 1, dy: 1).intersects(r)
    }

    private func motion(for c: Clip) -> CardMotion {
        if let m = motions[c.id] { return m }
        let m = CardMotion(clip: c, board: self)
        motions[c.id] = m
        return m
    }

    /// Sizes the scroll content and sets which way it scrolls: sideways in the row, down in the
    /// grid and history. When the content shrinks under the view (a card removed near the end)
    /// and `easeBack` is set, the view eases back on `settle` with the cards, and the document
    /// keeps its room until it gets there, so nothing jumps.
    private func sizeDocument(easeBack: Bool = false) {
        let row = mode == .row
        scrollView.horizontalScrollElasticity = row ? .allowed : .none
        scrollView.verticalScrollElasticity = row ? .none : .allowed
        let v = viewport, m = maxScroll
        if easeBack, !Motion.reduce, v.minX > m.x + 0.5 || v.minY > m.y + 0.5 {
            let d = scrollDestination
            scroll(to: CGPoint(x: min(d.x, m.x), y: min(d.y, m.y)), duration: Motion.settle)
        }
        var size = contentSize
        if scroller.sx.busy || scroller.sy.busy {
            size = CGSize(width: max(size.width, v.maxX), height: max(size.height, v.maxY))
        }
        if document.frame.size != size { document.setFrameSize(size) }
    }

    private func layoutHeaders(_ sections: [HistoryLayout.Section], kind: Kind, firstRow: Int) {
        var keep = Set<Date>()
        let color = model.theme.increaseContrast ? Palette.label2Contrast : Palette.label2
        for s in sections {
            keep.insert(s.day)
            let y = Double(s.y)
            if let h = headers[s.day] {
                h.view.set(text: s.label, color: color)
                if case .instant = kind { h.y.set(y) } else if Motion.reduce { h.y.set(y) } else { h.y.spring(to: y, duration: Motion.settle) }
            } else {
                let h = HeaderMotion(board: self)
                headers[s.day] = h
                h.view.set(text: s.label, color: color)
                document.addSubview(h.view)
                h.y.set(y)
                if case .mode = kind {
                    let row = origins[order[s.first].id]?.row ?? 0
                    bornHeader(h, delay: 20 * Double(max(0, row - firstRow)))
                }
                h.render()
            }
        }
        for (day, h) in headers where !keep.contains(day) {
            headers[day] = nil
            if case .instant = kind { h.view.removeFromSuperview(); continue }
            if Motion.reduce { h.view.removeFromSuperview(); continue }
            h.op.tween(to: 0, ms: 160, ease: Motion.leave)
            h.blur.tween(to: 8, ms: 160, ease: Motion.leave) { [weak h] in h?.view.removeFromSuperview() }
        }
    }

    private func layoutPlaceholders() {
        let n = placeholderRow ? grid.columns : 0
        while placeholders.count > n { placeholders.removeLast().removeFromSuperview() }
        while placeholders.count < n {
            let v = PlaceholderCardView()
            placeholders.append(v)
            document.addSubview(v, positioned: .below, relativeTo: nil)
        }
        for (i, v) in placeholders.enumerated() {
            v.frame = NSRect(x: grid.sidePadding + i * grid.pitchX, y: placeholderTop, width: grid.cardWidth, height: grid.cardHeight)
        }
    }

    // MARK: Entrances and exits

    /// Born blurred: blur → 0 (and scale, rise) on `settle`, opacity on `fadeIn` 140 ms.
    /// `focus`: the open's entrance, blur, scale and rise on `focus` over `focusMs` and opacity
    /// over `focusFadeMs`, instead of a spring.
    func born(_ m: CardMotion, blur px: Double, delay: Double = 0, scale: Double? = nil, rise: Double? = nil,
              focus: Bool = false) {
        if Motion.reduce {
            m.blur.set(0); m.es.set(1); m.dy.set(0)
            m.op.set(0); m.op.tween(to: 1, ms: 150)
            return
        }
        if focus {
            m.blur.set(px); m.blur.tween(to: 0, ms: Motion.focusMs, ease: Motion.focus, delay: delay)
            if let scale { m.es.set(scale); m.es.tween(to: 1, ms: Motion.focusMs, ease: Motion.focus, delay: delay) }
            if let rise { m.dy.set(rise); m.dy.tween(to: 0, ms: Motion.focusMs, ease: Motion.focus, delay: delay) }
            m.op.set(0); m.op.tween(to: 1, ms: Motion.focusFadeMs, ease: Motion.materialise, delay: delay)
            return
        }
        m.blur.set(px); m.blur.spring(to: 0, duration: Motion.settle, delay: delay)
        if let scale { m.es.set(scale); m.es.spring(to: 1, duration: Motion.settle, delay: delay) }
        if let rise { m.dy.set(rise); m.dy.spring(to: 0, duration: Motion.settle, delay: delay) }
        m.op.set(0); m.op.tween(to: 1, ms: 140, ease: Motion.fadeIn, delay: delay)
    }

    private func bornHeader(_ h: HeaderMotion, delay: Double) {
        if Motion.reduce {
            h.op.set(0); h.op.tween(to: 1, ms: 150)
            return
        }
        h.blur.set(12); h.blur.spring(to: 0, duration: Motion.settle, delay: delay)
        h.op.set(0); h.op.tween(to: 1, ms: 140, ease: Motion.fadeIn, delay: delay)
    }

    /// Accelerates out with a blur: opacity → 0, blur → 8 on `leave` 160 ms.
    func fadeOut(_ m: CardMotion, done: (() -> Void)? = nil) {
        if Motion.reduce { m.op.set(0); done?(); return }
        m.op.tween(to: 0, ms: 160, ease: Motion.leave)
        m.blur.tween(to: 8, ms: 160, ease: Motion.leave, done: done)
    }

    /// A removed card leaves: opacity 1 → 0, scale 1 → 0.92 and blur 0 → 8 on `leave` 160 ms,
    /// accelerating away, while the others close the gap on `settle` from the same moment and
    /// slide over it, so the gap never sits empty. Under Reduce Motion it fades over 0.12 s and the
    /// others jump.
    private func leave(_ m: CardMotion) {
        m.leaving = true
        leaving.append(m)
        m.pop.stop()
        m.dip.stop()
        m.cell?.layer?.zPosition = -1
        // Put away once every part of the exit has arrived.
        let done = { [weak self, weak m] in
            guard let self, let m, !m.gone, !m.op.busy, !m.es.busy, !m.blur.busy else { return }
            self.leaving.removeAll { $0 === m }
            self.drop(m)
        }
        if Motion.reduce {
            m.op.tween(to: 0, ms: 120, done: done)
        } else {
            m.op.tween(to: 0, ms: 160, ease: Motion.leave, done: done)
            m.es.tween(to: 0.92, ms: 160, ease: Motion.leave, done: done)
            m.blur.tween(to: 8, ms: 160, ease: Motion.leave, done: done)
        }
    }

    /// Off the board for good: its motion stops and its cell goes back to the pool with no filter
    /// left on it.
    private func drop(_ m: CardMotion) {
        m.gone = true
        m.leaving = false
        for a in m.anims { a.stop() }
        if let cell = m.cell {
            cell.place(x: m.x.v, y: m.y.v, size: cardSize, scale: 1, opacity: 0, blur: 0)
            cell.layer?.zPosition = 0
        }
        detach(m)
    }

    /// Open and close: no pop, dip, slide or leaving card carries over.
    private func settleCardMotion() {
        for m in leaving { drop(m) }
        leaving.removeAll()
        for m in motions.values {
            if m.pop.busy || m.pop.v != 1 { m.pop.set(1) }
            if m.dip.busy || m.dip.v != 1 { m.dip.set(1) }
        }
        ring.ox.set(0)
        ring.oy.set(0)
        ring.cardID = nil
        ring.drawn = nil
        ring.view.recolor()
        lastSelection = 0
    }

    /// Rows past `rowsShown` hide while the pill is dragged; a row that comes into view is born blurred.
    func applyConceal() {
        for m in motions.values {
            let hide = concealOn && mode == .grid && m.row >= rowsShown
            if hide && !m.concealed && !m.hiding {
                if Motion.reduce {
                    m.concealed = true
                    render(m)
                } else {
                    m.hiding = true
                    m.op.tween(to: 0, ms: 120, ease: Motion.leave) { [weak m] in
                        guard let m, m.hiding else { return }
                        m.hiding = false
                        m.concealed = true
                        m.op.set(1)
                    }
                }
            } else if !hide && (m.concealed || m.hiding) {
                m.hiding = false
                m.concealed = false
                if concealOn { born(m, blur: 12) } else { m.op.set(1); m.blur.set(0) }
                render(m)
            }
        }
    }

    // MARK: Selection, hover and press

    /// The selection moved to `id` (the ring follows by itself, see `renderRing`). The card pops
    /// 1.08, unless the last change was under 120 ms ago (a held arrow key), so a held key reads as
    /// the ring gliding along, not a jitter. Under Reduce Motion nothing pops.
    func selected(_ id: UUID, pop: Pop = .normal) {
        let now = CACurrentMediaTime()
        let held = (now - lastSelection) * 1000 < Motion.repeatMs
        lastSelection = now
        // Now, so the slide starts on the same frame as the scroll to the selection and they move in step.
        renderRing()
        guard !Motion.reduce, let m = motions[id] else { return }
        // 1.08 or 1.03, from Settings › Motion › Card pop.
        if pop == .force || (pop == .normal && !held) { m.pop.pop(Preferences.app.cardPop) }
    }

    /// Draws the ring around the selected card. When the selection changes while the ring shows,
    /// it slides from where it is: its offset from the new card springs to 0 on `quick` (bounce 0),
    /// keeping the speed it had, so a key that repeats re-aims it mid-flight and a held arrow key
    /// glides. If the new card is itself still moving into place (the neighbour closing the gap
    /// after a remove), the offset springs on `settle`, the card's own spring, so the ring holds
    /// still while the card slides into it. Under Reduce Motion, when it wasn't showing, or with
    /// Settings › Motion › Selection change set to One-frame flip, it appears on the card at once.
    func renderRing() {
        let r = ring
        guard let id = model.selectedID, let m = motions[id], !m.leaving, !m.gone else {
            // Only when needed: setting marks the ring for another draw, which would never end.
            for a in [r.ox, r.oy] where a.busy || a.v != 0 { a.set(0) }
            r.cardID = nil
            r.drawn = nil
            if !r.view.isHidden { r.view.isHidden = true }
            return
        }
        if r.cardID != id {
            let from = r.cardID != nil && !r.view.isHidden ? r.drawn : nil
            r.cardID = id
            if let from, !Motion.reduce, Preferences.app.selection == .slide {
                let duration = m.x.busy || m.y.busy ? Motion.settle : Motion.quick
                for (a, d) in [(r.ox, from.x - m.x.v), (r.oy, from.y - m.y.v)] {
                    let v = a.velocity
                    a.set(d)
                    if abs(d) > 0.05 || abs(v) > 0.6 { a.spring(to: 0, duration: duration, velocity: v) } else { a.set(0) }
                }
            } else {
                r.ox.set(0)
                r.oy.set(0)
            }
        }
        let p = CGPoint(x: m.x.v + r.ox.v, y: m.y.v + r.oy.v)
        r.drawn = p
        let o = m.concealed ? 0 : min(max(m.op.v, 0), 1) * (ghostID == id ? 0.35 : 1)
        r.view.place(card: CGRect(x: p.x, y: p.y + m.dy.v, width: Double(grid.cardWidth), height: Double(grid.cardHeight)),
                     width: model.theme.ringWidth, scale: m.scale, opacity: o, blur: m.blur.v)
        r.probe?(p)
    }

    /// A button under the pointer pops 1.08 (the fill flip is the view's); a card hover is a flip only.
    private func hoverChanged(from old: (UUID?, CardButton?), to new: (UUID?, CardButton?)) {
        guard !Motion.reduce, let id = new.0, let b = new.1, old.0 != id || old.1 != b else { return }
        if b == .copy, model.missing.contains(id) { return }
        motions[id]?.cell?.look.anim(b).pop()
    }

    /// Mouse down dips a card to 0.97 or a button to 0.92 in 70 ms and holds; release springs back
    /// on `quick`. Under Reduce Motion the views darken instead.
    private func pressChanged(from old: (UUID?, CardButton?), to new: (UUID?, CardButton?)) {
        guard !Motion.reduce else { return }
        if let id = old.0, let m = motions[id] {
            if let b = old.1 {
                m.cell?.look.anim(b).spring(to: 1, duration: Motion.quick)
            } else {
                m.dip.spring(to: 1, duration: Motion.quick)
            }
        }
        if let id = new.0, let m = motions[id] {
            if let b = new.1 {
                m.cell?.look.anim(b).tween(to: Motion.dipControl, ms: Motion.dipMs, ease: Motion.popUp)
            } else {
                m.dip.tween(to: Motion.dipCard, ms: Motion.dipMs, ease: Motion.popUp)
            }
        }
    }

    /// ⌘C or the copy button: the symbol hard-cuts to the checkmark on frame 0, inside the 1.08
    /// pop, whose 60 ms attack (the fastest segment) hides the swap. The revert after 1.5 s is a
    /// hard cut with no pop. Under Reduce Motion: the hard cut alone.
    func copyConfirmed(_ id: UUID) {
        guard !Motion.reduce else { return }
        motions[id]?.cell?.look.copy.pop()
    }

    /// The scale a card is drawn at now (pop and dip included).
    func scale(of id: UUID) -> Double { motions[id]?.scale ?? 1 }

    // MARK: Scroll

    /// Folds the scroll offset into every position and scrolls to 0, so a mode change can carry
    /// cards from where they are seen.
    func rebaseScroll() {
        let o = viewport.origin
        scroller.sx.stop(); scroller.sy.stop()
        guard o != .zero else { return }
        for m in motions.values { m.x.shift(by: -o.x); m.y.shift(by: -o.y) }
        for h in headers.values { h.y.shift(by: -o.y) }
        ring.drawn = ring.drawn.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }
        scrollNow(to: .zero)
    }

    var maxScroll: CGPoint {
        let v = viewport.size
        return CGPoint(x: max(0, contentSize.width - v.width), y: max(0, contentSize.height - v.height))
    }

    /// Scrolls on `quick` (or `duration`), instantly under Reduce Motion or when asked.
    func scroll(to p: CGPoint, instant: Bool = false, duration: Double = Motion.quick) {
        let m = maxScroll
        let t = CGPoint(x: min(max(p.x, 0), m.x), y: min(max(p.y, 0), m.y))
        let cur = viewport.origin
        if instant || Motion.reduce {
            scroller.sx.set(t.x); scroller.sy.set(t.y)
            scrollNow(to: t)
            return
        }
        if !scroller.sx.busy { scroller.sx.set(cur.x) }
        if !scroller.sy.busy { scroller.sy.set(cur.y) }
        if abs(t.x - scroller.sx.dest) > 0.5 { scroller.sx.spring(to: t.x, duration: duration) }
        if abs(t.y - scroller.sy.dest) > 0.5 { scroller.sy.spring(to: t.y, duration: duration) }
    }

    /// A scroll by the user stops any programmatic one.
    func userScrolled() {
        scroller.sx.stop()
        scroller.sy.stop()
    }

    /// Where a running programmatic scroll is heading, or where the view is.
    var scrollDestination: CGPoint {
        CGPoint(x: scroller.sx.busy ? scroller.sx.dest : viewport.origin.x,
                y: scroller.sy.busy ? scroller.sy.dest : viewport.origin.y)
    }

    func scrollNow(to p: CGPoint) {
        let clip = scrollView.contentView
        let q = NSPoint(x: pixelSnap(p.x), y: pixelSnap(p.y))
        guard clip.bounds.origin != q else { return }
        clip.scroll(to: q)
        scrollView.reflectScrolledClipView(clip)
    }

    private func scrolled() {
        scrollSettled()
        updateCells()
        onScroll?()
    }

    /// An ease-back after a remove has arrived: the document shrinks to the content.
    func scrollSettled() {
        if document.frame.size != contentSize, !scroller.sx.busy, !scroller.sy.busy { sizeDocument() }
    }

    // MARK: Cells

    func render(_ m: CardMotion) {
        guard !m.gone else { return }
        if m.cell == nil {
            guard !m.leaving, needsCell(m) else { return }
            attach(m)
        }
        guard let cell = m.cell else { return }
        let ghost = ghostID == m.id
        let o = m.concealed ? 0 : min(max(m.op.v, 0), 1) * (ghost ? 0.35 : 1)
        cell.place(x: m.x.v, y: m.y.v + m.dy.v, size: cardSize, scale: m.scale, opacity: o, blur: m.blur.v)
        // The ring is drawn in the same frame as its card, never a frame behind.
        if m.id == model.selectedID { renderRing() }
    }

    private func needsCell(_ m: CardMotion) -> Bool {
        let v = viewport.insetBy(dx: -CGFloat(grid.pitchX), dy: -CGFloat(grid.pitchY))
        return v.intersects(m.rect) || ghostID == m.id
    }

    /// Gives every card in view a cell and takes cells back from cards far out of view.
    func updateCells() {
        for m in motions.values {
            if needsCell(m) {
                if m.cell == nil { attach(m); render(m) }
            } else if m.cell != nil, !m.busy {
                detach(m)
            }
        }
    }

    private func attach(_ m: CardMotion) {
        let cell = pool.popLast() ?? CardCell(model: model)
        cell.show(m.clip)
        cell.isHidden = false
        if cell.superview !== document { document.addSubview(cell) }
        cell.look.isLive = { [weak self, weak cell] in
            guard let self, let cell, !cell.isHidden else { return false }
            return self.isLive && self.viewport.intersects(cell.frame)
        }
        m.cell = cell
        cells[m.id] = cell
    }

    /// A put-away cell shows nothing, so it neither draws nor re-renders when the model changes
    /// (with a few hundred cells kept bound to old clips, every hover cost 60 ms). The pool keeps
    /// enough for a full 3-row panel; the rest are let go.
    private func detach(_ m: CardMotion) {
        guard let cell = m.cell else { return }
        m.cell = nil
        if cells[m.id] === cell { cells[m.id] = nil }
        cell.isHidden = true
        cell.look.rest()
        cell.clear()
        if pool.count < Self.poolLimit {
            pool.append(cell)
        } else {
            cell.removeFromSuperview()
        }
    }

    static let poolLimit = 32

    /// Drops every card and cell (the panel closed or the screen changed).
    func reset() {
        for m in leaving { drop(m) }
        leaving.removeAll()
        for m in motions.values { drop(m) }
        motions.removeAll()
        for h in headers.values { h.view.removeFromSuperview() }
        headers.removeAll()
        placeholderRow = false
        layoutPlaceholders()
        ghostID = nil
        concealOn = false
        renderRing()
    }

    // MARK: Queries

    /// The card under a point in the scroll content, and the point inside it.
    func card(at p: CGPoint) -> (id: UUID, local: CGPoint)? {
        for m in motions.values where m.cell != nil && !m.concealed && m.op.v > 0.05 {
            let r = m.rect
            if r.contains(p) { return (m.id, CGPoint(x: p.x - r.minX, y: p.y - r.minY)) }
        }
        return nil
    }

    /// Where a card rests (its target), in the scroll content.
    func restingRect(_ id: UUID) -> CGRect? {
        guard let o = origins[id] else { return nil }
        return CGRect(x: o.x, y: o.y, width: grid.cardWidth, height: grid.cardHeight)
    }

    /// Where a card is drawn now, in the scroll content.
    func currentRect(_ id: UUID) -> CGRect? { motions[id]?.rect }

    var isMoving: Bool { motions.values.contains { $0.busy } }

    /// For the geometry log.
    func cellFrames(_ n: Int) -> [CGRect] {
        order.prefix(n).compactMap { motions[$0.id]?.rect }
    }
}

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
    var clip: Clip
    var placed = false
    /// Hidden while the pill is dragged until its row is uncovered.
    var concealed = false
    var hiding = false
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
        for a in [x, y, dy, op, blur, es] { a.owner = self }
    }

    var busy: Bool { x.busy || y.busy || dy.busy || op.busy || blur.busy || es.busy }
    /// The rect it is drawn at now, in the scroll content.
    var rect: CGRect {
        CGRect(x: x.v, y: y.v + dy.v, width: Double(board.grid.cardWidth), height: Double(board.grid.cardHeight))
    }

    func render() { board.render(self) }
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

    func render() { board.scrollNow(to: CGPoint(x: sx.v, y: sy.v)) }
}

/// The cards in the panel: their layout in row, grid and history mode, their motion, and the
/// cells that draw the ones in view (cells exist only for visible cards, recycled as you scroll).
@MainActor
final class Board {
    enum Kind {
        /// Everything jumps to its place.
        case instant
        /// Everything slides to its new place on `settle` (reorder, remove, insert).
        case reflow
        /// A mode change: cards in view before and after are carried on `settle`, cards arriving
        /// are born blurred 20 ms apart per row, cards leaving blur out on `leave`. The rects are
        /// the viewport before and after, with the scroll offset already folded into positions.
        case mode(before: CGRect, after: CGRect)
    }

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
    private var headers: [Date: HeaderMotion] = [:]
    private var cells: [UUID: CardCell] = [:]
    private var pool: [CardCell] = []
    private var placeholders: [PlaceholderCardView] = []
    private(set) var placeholderRow = false
    private var generation = 0
    private(set) lazy var scroller = ScrollMotion(board: self)

    /// While the pill is dragged, rows past `rowsShown` stay hidden until their boundary is crossed.
    var concealOn = false
    var rowsShown = 1
    /// The lifted card: drawn at 35% where it will land.
    var ghostID: UUID? { didSet { if let o = oldValue { motions[o].map(render) }; if let g = ghostID { motions[g].map(render) } } }
    /// Called after every scroll, by the user or by code.
    var onScroll: (() -> Void)?

    var grid: PanelGrid { model.geometry.grid }
    var viewport: CGRect { scrollView.contentView.bounds }
    var cardSize: CGSize { CGSize(width: grid.cardWidth, height: grid.cardHeight) }

    init(model: PanelModel, content: PanelContentView) {
        self.model = model
        self.content = content
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
        // A few cells ready before the first open.
        for _ in 0..<12 { pool.append(CardCell(model: model)) }
    }

    // MARK: Layout

    /// Lays `clips` out for `mode` and moves every card to its place as `kind` says.
    func layout(_ clips: [Clip], mode newMode: PanelMode, kind: Kind, placeholders wantPlaceholders: Bool = false) {
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
        sizeDocument()

        // Cards.
        var firstRow = Int.max
        if case .mode(_, let after) = kind {
            for o in pos.values where visible(o, in: after) { firstRow = min(firstRow, o.row) }
        }
        if firstRow == Int.max { firstRow = 0 }
        var keep = Set<UUID>()
        for c in clips {
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
            detach(m)
            motions[id] = nil
        }
        layoutHeaders(sections, kind: kind, firstRow: firstRow)
        layoutPlaceholders()
        updateCells()
    }

    private var placeholderTop = 0

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
    /// grid and history.
    private func sizeDocument() {
        let row = mode == .row
        scrollView.horizontalScrollElasticity = row ? .allowed : .none
        scrollView.verticalScrollElasticity = row ? .none : .allowed
        if document.frame.size != contentSize { document.setFrameSize(contentSize) }
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
    func born(_ m: CardMotion, blur px: Double, delay: Double = 0, scale: Double? = nil, rise: Double? = nil) {
        if Motion.reduce {
            m.blur.set(0); m.es.set(1); m.dy.set(0)
            m.op.set(0); m.op.tween(to: 1, ms: 150)
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

    // MARK: Scroll

    /// Folds the scroll offset into every position and scrolls to 0, so a mode change can carry
    /// cards from where they are seen.
    func rebaseScroll() {
        let o = viewport.origin
        scroller.sx.stop(); scroller.sy.stop()
        guard o != .zero else { return }
        for m in motions.values { m.x.shift(by: -o.x); m.y.shift(by: -o.y) }
        for h in headers.values { h.y.shift(by: -o.y) }
        scrollNow(to: .zero)
    }

    var maxScroll: CGPoint {
        let v = viewport.size
        return CGPoint(x: max(0, contentSize.width - v.width), y: max(0, contentSize.height - v.height))
    }

    /// Scrolls on `quick` (instantly under Reduce Motion or when asked).
    func scroll(to p: CGPoint, instant: Bool = false) {
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
        if abs(t.x - scroller.sx.dest) > 0.5 { scroller.sx.spring(to: t.x, duration: Motion.quick) }
        if abs(t.y - scroller.sy.dest) > 0.5 { scroller.sy.spring(to: t.y, duration: Motion.quick) }
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
        updateCells()
        onScroll?()
    }

    // MARK: Cells

    func render(_ m: CardMotion) {
        if m.cell == nil {
            guard needsCell(m) else { return }
            attach(m)
        }
        guard let cell = m.cell else { return }
        let ghost = ghostID == m.id
        let o = m.concealed ? 0 : min(max(m.op.v, 0), 1) * (ghost ? 0.35 : 1)
        cell.place(x: m.x.v, y: m.y.v + m.dy.v, size: cardSize, scale: m.es.v, opacity: o, blur: m.blur.v)
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
        m.cell = cell
        cells[m.id] = cell
    }

    private func detach(_ m: CardMotion) {
        guard let cell = m.cell else { return }
        m.cell = nil
        cells[m.id] = nil
        cell.isHidden = true
        pool.append(cell)
    }

    /// Drops every card and cell (the panel closed or the screen changed).
    func reset() {
        for m in motions.values { detach(m) }
        motions.removeAll()
        for h in headers.values { h.view.removeFromSuperview() }
        headers.removeAll()
        placeholderRow = false
        layoutPlaceholders()
        ghostID = nil
        concealOn = false
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

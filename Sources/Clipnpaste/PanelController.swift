import AppKit
import Carbon
import SwiftUI
import ClipnpasteCore

/// Owns the panel: built once at launch, then only ordered in and out. Routes every key and
/// click itself (the views only draw), and runs the paste path.
@MainActor
final class PanelController {
    static let clipLimit = 200
    private static let classicBlurKey = "useClassicBlur"
    private static let toastText = "Copied. Press ⌘V to paste."
    /// Older clips page into history this many at a time.
    static var historyPage: Int { DebugFlags.historyPage ?? 200 }

    let store: any ClipStore
    let watcher: any ClipboardWatcher
    let panel = ClipPanel()
    let root = PanelRootView()
    let model: PanelModel
    let surface: GlassSurface
    let content: PanelContentView
    let board: Board
    let toast = Toast()
    private var storeToken: UUID?
    private var clickMonitor: Any?
    private var moveMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    var stale = true
    var screen: NSScreen?
    /// The app that was in front when the panel opened; the paste goes there.
    private var previousApp: NSRunningApplication?
    var press: Press?
    private var markTokens: [UUID: UUID] = [:]

    // Height, mode and gestures (see PanelController+Height.swift and CardDrag.swift).
    var rows = 1
    var strip: Strip = .full
    private(set) lazy var glass = GlassMotion(controller: self)
    var pill: PillDrag?
    var pillHovered = false
    /// The History button is held; true while the pointer is still on it.
    var historyPress: Bool?
    var history = HistoryState()
    var drag: CardDrag?
    let dragSource = DragSource()
    /// `--self-test`: records a paste instead of making one, so the clipboard is never touched.
    var pasteInterceptor: ((UUID) -> Void)?
    /// `--self-test`: an intercepted paste still runs the exit, as a real one does.
    var interceptedPasteCloses = false

    /// Closed, opening, open or closing (see PanelMotion.swift).
    var phase: PanelPhase = .closed
    /// Opening or open: the panel takes keys and clicks. A closing panel is still on screen.
    var isOpen: Bool { phase == .opening || phase == .open }
    private(set) lazy var rise = RiseMotion(controller: self)

    struct Press {
        let id: UUID
        let button: CardButton?
        let start: NSPoint
        var moved = false
    }

    enum Hit {
        case outside, panel, pill, history
        case card(UUID)
        case button(UUID, CardButton)
    }

    enum Strip { case full, strip }

    var useClassicBlur: Bool {
        get { UserDefaults.standard.bool(forKey: Self.classicBlurKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.classicBlurKey)
            refreshDisplayOptions()
        }
    }

    /// `--self-test`: runs the panel on a given surface without touching the saved setting.
    var materialOverride: GlassSurface.Material?

    var material: GlassSurface.Material {
        if let m = materialOverride { return m }
        guard useClassicBlur else { return .glass }
        return model.theme.reduceTransparency ? .opaque : .classic
    }

    init(store: any ClipStore, watcher: any ClipboardWatcher) {
        self.store = store
        self.watcher = watcher
        let model = PanelModel()
        self.model = model
        content = PanelContentView(model: model)
        board = Board(model: model, content: content)
        surface = GlassSurface(content: content, cornerRadius: PanelGeometry.radius, material: .glass)

        root.wantsLayer = true
        root.addSubview(surface)
        panel.testDriven = DebugFlags.drivesPanel
        panel.ignoresMouseEvents = false
        panel.contentView = root
        panel.router = { [unowned self] in self.route($0) }
        panel.onResignKey = { [unowned self] in
            // A drag into another app may take the keyboard; the panel stays for the next drag.
            if self.drag == nil, !DebugFlags.drivesPanel { self.close() }
        }
        root.onMouseMoved = { [unowned self] p in
            self.hover(at: p)
            self.updatePassThrough(self.panel.convertPoint(toScreen: p))
        }
        root.onMouseExited = { [unowned self] in self.hover(at: nil) }
        board.onScroll = { [unowned self] in
            self.refreshHover()
            self.historyScrolled()
        }
        model.onOpenSettings = { [unowned self] in
            let pasteboard = !self.model.needsAccessibility && self.model.needsPasteboardAccess
            self.close()
            if pasteboard { Self.openPasteboardSettings() } else { Paster.openAccessibilitySettings() }
        }
        dragSource.controller = self
        storeToken = store.addObserver { [weak self] _ in self?.storeChanged() }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshDisplayOptions() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } })

        Diagnostics.shared.configure()
        // One layout pass now, off screen, so the first open has nothing to build.
        applyDisplayOptions()
        layout(on: mouseScreen())
        rows = savedRows()
        model.mode = rows > 1 ? .grid : .row
        reload(.instant)
        glass.h.set(targetHeight)
        MotionClock.shared.flush()
        root.layoutSubtreeIfNeeded()
        warmUp()
    }

    /// Shows the window once at zero alpha and takes it away again, with the visible cards built,
    /// so the first open after launch costs what every later one does.
    private func warmUp() {
        board.updateCells()
        MotionClock.shared.flush()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    // MARK: Open and close

    func toggle() { isOpen ? close() : open() }

    func open() {
        if phase == .closing { return reopenMidExit() }
        guard phase == .closed else { return }
        let started = CACurrentMediaTime()
        Diagnostics.shared.triggered()
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        var marks: [(String, Double)] = []
        func mark(_ n: String) { if DebugFlags.logGeometry { marks.append((n, (CACurrentMediaTime() - started) * 1000)) } }
        (watcher as? PasteboardWatcher)?.checkNow()
        mark("watcher")
        layout(on: mouseScreen())
        mark("layout")
        applyDisplayOptions()
        mark("display options")
        model.now = Date()
        model.marks = [:]
        markTokens = [:]
        rows = savedRows()
        strip = .full
        model.mode = rows > 1 ? .grid : .row
        reload(.instant)
        mark("reload")
        model.selectedID = model.clips.first?.id
        model.focus = .card
        model.needsAccessibility = !Paster.canPost
        model.needsPasteboardAccess = Self.pasteboardAsks
        glass.h.set(targetHeight)
        glass.fade.set(1)
        glass.shift.set(0)
        board.scroll(to: .zero, instant: true)
        fitWindow()
        updateChrome()
        MotionClock.shared.use(screen: screen)
        // The from-state is drawn before the window shows, so its first frame starts the rise.
        startRise()
        MotionClock.shared.flush()
        mark("cards placed")

        phase = .opening
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        Diagnostics.shared.orderedFront(on: screen)
        takeInput()
        refreshHover()
        updatePassThrough()
        mark("ordered front")
        if DebugFlags.demoStates { applyDemoStates() }
        logOpen(ms: (CACurrentMediaTime() - started) * 1000)
        if DebugFlags.logGeometry { debugLog("open steps: " + marks.map { "\($0.0) \(String(format: "%.1f", $0.1))" }.joined(separator: ", ")) }
    }

    /// The shortcut pressed while the panel leaves: it turns back from where it is.
    private func reopenMidExit() {
        Diagnostics.shared.triggered()
        reaimOpen()
        panel.ignoresMouseEvents = false
        Diagnostics.shared.orderedFront(on: screen)
        takeInput()
        refreshHover()
        updatePassThrough()
    }

    /// The keyboard and the global monitors, while the panel is open.
    private func takeInput() {
        // A self-test or scene run drives the panel with its own events: it never takes the
        // keyboard, and clicks in other apps don't close it.
        guard !DebugFlags.drivesPanel else { return }
        panel.makeKey()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // Outside the glass the window lets clicks through to the apps below; this notices the
        // pointer coming back over the glass.
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMovedElsewhere() }
        }
    }

    /// Input stops at once; the panel then leaves on its exit motion and is ordered out when it
    /// ends (`finishClose`). Clicks go through to the apps below while it leaves.
    func close() {
        guard isOpen else { return }
        phase = .closing
        for m in [clickMonitor, moveMonitor] { if let m { NSEvent.removeMonitor(m) } }
        clickMonitor = nil
        moveMonitor = nil
        if let d = drag { finishDrag(d) }
        if pill != nil {
            pill = nil
            board.concealOn = false
            board.applyConceal()
        }
        pillHovered = false
        content.topBar.pill.setLook(.rest)
        historyPress = nil
        content.topBar.history.pressed = false
        content.topBar.history.hovered = false
        press = nil
        model.setPressed(nil, nil)
        model.setHover(nil, nil)
        panel.ignoresMouseEvents = true
        NSCursor.arrow.set()
        startExit()
    }

    /// The exit has ended: ordered out, and everything back at rest for the next open.
    func finishClose() {
        guard phase == .closing else { return }
        phase = .closed
        panel.orderOut(nil)
        panel.ignoresMouseEvents = false
        rise.y.set(0)
        rise.op.set(1)
        for m in rise.blurred { m.blur.set(0) }
        rise.blurred = []
        content.emptyFx.reset()
        // The banners flip in again, dot popping, on the next open.
        model.needsAccessibility = false
        model.needsPasteboardAccess = false
        // Next time it opens on the row or grid again, at its remembered height.
        history = HistoryState(token: history.token + 1)
        strip = .full
        model.mode = rows > 1 ? .grid : .row
        glass.h.stop()
        glass.fade.set(1)
        glass.shift.set(0)
        reload(.instant)
        glass.h.set(targetHeight)
        MotionClock.shared.flush()
        Diagnostics.shared.closed()
    }

    /// Pasteboard privacy set to ask or deny: the second banner.
    static var pasteboardAsks: Bool {
        if DiagnosticFlags.pasteboardBanner { return true }
        let b = NSPasteboard.general.accessBehavior
        return b == .ask || b == .alwaysDeny
    }

    static func openPasteboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
            NSWorkspace.shared.open(url)
        }
    }

    private func mouseScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Sizes everything from the screen's visible frame, read fresh on every open.
    private func layout(on screen: NSScreen?) {
        guard let screen else { return }
        self.screen = screen
        let vf = screen.visibleFrame
        let g = PanelGeometry(visibleWidth: Int(vf.width), visibleHeight: Int(vf.height), screenHeight: Int(screen.frame.height))
        if g != model.geometry {
            model.geometry = g
            board.reset()
        }
        content.topBar.use(g)
        let f = windowFrame(glassHeight: Double(g.height))
        if panel.frame != f { panel.setFrame(f, display: false) }
    }

    /// A setting changed while the app runs. A new surface (Reduce Transparency's opaque one, or
    /// classic blur) is drawn once off screen while closed, so the next rise keeps its frames.
    private func refreshDisplayOptions() {
        let before = surface.material
        applyDisplayOptions()
        if phase == .closed, surface.material != before { warmUp() }
    }

    func applyDisplayOptions() {
        let ws = NSWorkspace.shared
        model.theme = Theme(
            increaseContrast: DebugFlags.increaseContrast || ws.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: DebugFlags.reduceTransparency || ws.accessibilityDisplayShouldReduceTransparency,
            reduceMotion: DebugFlags.reduceMotion || ws.accessibilityDisplayShouldReduceMotion)
        Motion.reduce = model.theme.reduceMotion
        surface.material = material
        surface.increaseContrast = model.theme.increaseContrast
        content.topBar.pill.increaseContrast = model.theme.increaseContrast
    }

    // MARK: Clips

    private func storeChanged() {
        if isOpen { reload(.reflow) } else { stale = true }
    }

    /// Reads the clips for the current mode and lays the cards out.
    func reload(_ kind: Board.Kind = .reflow) {
        stale = false
        model.totalCount = store.count
        if model.mode == .history {
            history.loaded = store.newestByDate(max(history.loaded.count, Self.historyPage))
            history.hasMore = history.loaded.count < store.count
            model.clips = history.loaded
        } else {
            model.clips = store.ordered(Self.clipLimit)
        }
        let ids = Set(model.clips.map(\.id))
        if let sel = model.selectedID, !ids.contains(sel) { model.selectedID = nil }
        if model.selectedID == nil {
            model.selectedID = model.clips.first?.id
            model.focus = .card
        }
        layoutBoard(kind)
        updateChrome()
    }

    /// Lays the cards out; while a card is dragged in the row or grid, with its slot open.
    func layoutBoard(_ kind: Board.Kind) {
        var clips = model.clips
        if let d = drag, d.reorderable, let i = clips.firstIndex(where: { $0.id == d.id }) {
            clips = Reorder.order(clips, moving: i, to: d.slot)
        }
        board.layout(clips, mode: model.mode, kind: kind, placeholders: model.mode == .history && history.hasMore)
    }

    // MARK: Events

    func route(_ event: NSEvent) -> NSEvent? {
        guard isOpen else {
            if phase == .closing, event.type == .keyDown { keyDuringExit(event); return nil }
            return event
        }
        if DebugFlags.traceEvents, [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
            debugLog("event \(event.type.rawValue) at \(event.locationInWindow) press \(press != nil) drag \(drag != nil) pill \(pill != nil)")
        }
        switch event.type {
        case .keyDown:
            handleKey(event)
            return nil
        case .leftMouseDown:
            return mouseDown(event)
        case .leftMouseDragged:
            return mouseDragged(event)
        case .leftMouseUp:
            return mouseUp(event)
        case .rightMouseDown, .otherMouseDown:
            if case .outside = hit(event.locationInWindow) { close() }
            return nil
        case .scrollWheel:
            guard strip == .full, pill == nil, drag == nil else { return nil }
            Diagnostics.shared.scrolled()
            board.userScrolled()
            if model.mode == .row, let sideways = Self.wheelAsSideways(event) {
                content.scrollView.scrollWheel(with: sideways)
            } else {
                content.scrollView.scrollWheel(with: event)
            }
            return nil
        default:
            return event
        }
    }

    /// A key typed while the panel leaves belongs to the app below: the exit ends at once (which
    /// hands the keyboard back) and the key is sent on to that app.
    private func keyDuringExit(_ event: NSEvent) {
        cutExit()
        guard !DebugFlags.drivesPanel, Paster.canPost, let cg = event.cgEvent?.copy() else { return }
        cg.post(tap: .cgSessionEventTap)
    }

    private func handleKey(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command), opt = flags.contains(.option), ctrl = flags.contains(.control)
        // A held pill or card takes no keys, except Esc to drop a card back.
        if pill != nil { return }
        if let d = drag {
            if Int(e.keyCode) == kVK_Escape, d.phase == .drag { cancelDrag(d) }
            return
        }
        switch Int(e.keyCode) {
        case kVK_Escape:
            close()
        case kVK_LeftArrow, kVK_RightArrow:
            let d = Int(e.keyCode) == kVK_LeftArrow ? -1 : 1
            if cmd && opt {
                moveSelected(by: d)
            } else if cmd {
                selectIndex(d < 0 ? 0 : model.clips.count - 1)
            } else {
                step(d)
            }
        case kVK_UpArrow, kVK_DownArrow:
            let up = Int(e.keyCode) == kVK_UpArrow
            if opt && !cmd {
                stepRows(up ? 1 : -1)
            } else if !cmd {
                moveVertically(up ? -1 : 1)
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !e.isARepeat { activateFocus() }
        case kVK_Space:
            if model.focus != .card, !e.isARepeat { activateFocus() }
        case kVK_Tab:
            cycleFocus(flags.contains(.shift) ? -1 : 1)
        case kVK_Delete, kVK_ForwardDelete:
            if let id = model.selectedID { remove(id) }
        default:
            let key = e.charactersIgnoringModifiers?.lowercased()
            if cmd, !ctrl, !opt, key == "c", let id = model.selectedID {
                copy(id)
            } else if cmd, !ctrl, !opt, key == "y", !e.isARepeat {
                toggleHistory()
            }
        }
    }

    private func mouseDown(_ event: NSEvent) -> NSEvent? {
        let p = event.locationInWindow
        switch hit(p) {
        case .outside:
            close()
            return nil
        case .panel:
            return event
        case .pill:
            if pillEnabled, strip == .full, drag == nil { pillDown(event) }
            return nil
        case .history:
            if historyEnabled {
                historyPress = true
                content.topBar.history.pressed = true
            }
            return nil
        case .card(let id):
            press = Press(id: id, button: nil, start: p)
            model.setPressed(id, nil)
            return nil
        case .button(let id, let b):
            if b == .copy, model.missing.contains(id) { return nil }
            press = Press(id: id, button: b, start: p)
            model.setPressed(id, b)
            return nil
        }
    }

    private func mouseDragged(_ event: NSEvent) -> NSEvent? {
        if pill != nil {
            pillMove(event)
            return nil
        }
        if let d = drag {
            if d.phase == .drag { dragDragged(d, event) }
            return nil
        }
        if historyPress != nil {
            var inside = false
            if case .history = hit(event.locationInWindow) { inside = true }
            historyPress = inside
            content.topBar.history.pressed = inside
            return nil
        }
        guard var p = press else { return event }
        let loc = event.locationInWindow
        if p.button == nil, !p.moved, hypot(loc.x - p.start.x, loc.y - p.start.y) >= PanelGrid.dragThreshold {
            p.moved = true
            press = p
            model.setPressed(nil, nil)
            // Past 4 pt the press is a drag: the card lifts. A missing image can only be removed.
            if let clip = clip(p.id), !model.missing.contains(clip.id) {
                liftDrag(clip, grabbedAt: p.start, event: event)
            } else {
                press = nil
            }
        }
        return nil
    }

    private func mouseUp(_ event: NSEvent) -> NSEvent? {
        if pill != nil {
            pillUp(event)
            return nil
        }
        if let d = drag {
            if d.phase == .drag { dragReleased(d, event) }
            return nil
        }
        if let inside = historyPress {
            historyPress = nil
            content.topBar.history.pressed = false
            if inside { toggleHistory() }
            refreshHover()
            return nil
        }
        guard let p = press else { return event }
        press = nil
        model.setPressed(nil, nil)
        if let b = p.button {
            if case .button(let id, let upOn) = hit(event.locationInWindow), upOn == b, id == p.id {
                b == .copy ? copy(p.id) : remove(p.id)
            }
        } else if !p.moved {
            select(p.id)
            paste(p.id)
        }
        refreshHover()
        return nil
    }

    /// A mouse wheel's vertical notches, as a sideways scroll for the row. Nil for trackpad
    /// scrolls and horizontal wheels, which pass through untouched.
    private static func wheelAsSideways(_ event: NSEvent) -> NSEvent? {
        guard !event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let cg = event.cgEvent?.copy() else { return nil }
        let ints: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
        ]
        for (v, h) in ints {
            cg.setIntegerValueField(h, value: cg.getIntegerValueField(v))
            cg.setIntegerValueField(v, value: 0)
        }
        let fixed = (CGEventField.scrollWheelEventFixedPtDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis2)
        cg.setDoubleValueField(fixed.1, value: cg.getDoubleValueField(fixed.0))
        cg.setDoubleValueField(fixed.0, value: 0)
        return NSEvent(cgEvent: cg)
    }

    /// What is under a point in window coordinates.
    func hit(_ p: NSPoint) -> Hit {
        let f = surface.frame
        guard f.contains(p) else { return .outside }
        guard strip == .full else { return .panel }
        let x = p.x - f.minX, y = f.maxY - p.y
        let local = NSPoint(x: x, y: y)
        if pillVisible, PillView.hitRect(panelWidth: f.width).contains(local) { return .pill }
        if y < CGFloat(CardLayout.topBar), HistoryButtonView.rect(panelWidth: f.width).contains(local) { return .history }
        let sy = y - CGFloat(PanelGrid.scrollTop)
        guard sy >= 0, !model.clips.isEmpty else { return .panel }
        let v = board.viewport
        guard let (id, l) = board.card(at: CGPoint(x: x + v.minX, y: sy + v.minY)) else { return .panel }
        // 20 pt buttons, 6 pt from the right edge and 4 pt apart, centred in the 26 pt header.
        if l.y >= 3, l.y < 23 {
            let right = CGFloat(model.geometry.cardWidth - 6)
            if l.x >= right - 20, l.x < right { return .button(id, .remove) }
            if l.x >= right - 44, l.x < right - 24 { return .button(id, .copy) }
        }
        return .card(id)
    }

    private func hover(at p: NSPoint?) {
        guard isOpen, press == nil, pill == nil, drag == nil, historyPress == nil else { return }
        var overPill = false, overHistory = false
        if let p {
            switch hit(p) {
            case .card(let id): model.setHover(id, nil)
            case .button(let id, let b): model.setHover(id, b)
            case .pill:
                overPill = true
                model.setHover(nil, nil)
            case .history:
                overHistory = true
                model.setHover(nil, nil)
            default: model.setHover(nil, nil)
            }
        } else {
            model.setHover(nil, nil)
        }
        setPillHover(overPill)
        content.topBar.history.hovered = overHistory && historyEnabled
    }

    func refreshHover() {
        guard isOpen, !DebugFlags.drivesPanel else { return }
        hover(at: panel.convertPoint(fromScreen: NSEvent.mouseLocation))
    }

    private func setPillHover(_ on: Bool) {
        guard on != pillHovered else { return }
        pillHovered = on
        content.topBar.pill.setLook(on ? .hover : .rest)
        (on ? Self.resizeCursor(.all) : NSCursor.arrow).set()
    }

    /// Outside the glass, clicks go through to the apps below; over it, the panel takes them.
    func updatePassThrough(_ point: NSPoint? = nil) {
        guard isOpen else { return }
        if let d = drag, d.phase == .session { return }
        if pill != nil || press != nil || historyPress != nil || drag != nil {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            return
        }
        let p = point ?? NSEvent.mouseLocation
        let pass = !glassScreenRect.contains(p)
        if panel.ignoresMouseEvents != pass { panel.ignoresMouseEvents = pass }
    }

    private func pointerMovedElsewhere() {
        guard isOpen else { return }
        let p = NSEvent.mouseLocation
        updatePassThrough(p)
        if !panel.ignoresMouseEvents { hover(at: panel.convertPoint(fromScreen: p)) } else { hover(at: nil) }
    }

    /// The glass on screen, as drawn now.
    var glassScreenRect: NSRect { panel.convertToScreen(surface.frame) }

    // MARK: Selection and focus

    private func step(_ d: Int) {
        guard !model.clips.isEmpty else { return }
        let i = model.selectedIndex.map { $0 + d } ?? 0
        selectIndex(min(max(i, 0), model.clips.count - 1))
    }

    func selectIndex(_ i: Int) {
        guard model.clips.indices.contains(i) else { return }
        select(model.clips[i].id)
    }

    func select(_ id: UUID) {
        if model.selectedID != id { model.selectedID = id }
        if model.focus != .card { model.focus = .card }
        scrollToSelection()
    }

    /// ↑ and ↓ in the grid and history: the same column in the row above or below (or its last card).
    private func moveVertically(_ d: Int) {
        guard model.mode != .row, let id = model.selectedID else { return }
        let rows = board.rows
        guard let r = rows.firstIndex(where: { $0.contains(id) }), let col = rows[r].firstIndex(of: id),
              rows.indices.contains(r + d), !rows[r + d].isEmpty else { return }
        select(rows[r + d][min(col, rows[r + d].count - 1)])
    }

    /// Keeps the selected card in view with one card of margin, on `quick`.
    func scrollToSelection(instant: Bool = false) {
        guard let id = model.selectedID, let r = board.restingRect(id) else { return }
        let g = model.geometry.grid
        let dest = board.scrollDestination
        if model.mode == .row {
            let m = CGFloat(g.pitchX), pad = CGFloat(g.sidePadding), w = CGFloat(model.geometry.width)
            var t = dest.x
            if r.minX - m < t + pad {
                t = r.minX - m - pad
            } else if r.maxX + m > t + w - pad {
                t = r.maxX + m - w + pad
            }
            if abs(t - dest.x) > 0.5 { board.scroll(to: CGPoint(x: t, y: 0), instant: instant) }
        } else {
            let viewH = CGFloat(glass.h.dest) - CGFloat(PanelGrid.scrollTop)
            let head = CGFloat(model.mode == .history ? PanelGrid.headerHeight : 0)
            let m = min(CGFloat(g.pitchY), max(0, (viewH - CGFloat(g.cardHeight) - head) / 2))
            let top = r.minY - m - head, bottom = r.maxY + m
            var t = dest.y
            if top < t {
                t = top
            } else if bottom > t + viewH {
                t = bottom - viewH
            }
            let maxY = max(0, board.contentSize.height - viewH)
            t = min(max(t, 0), maxY)
            if abs(t - dest.y) > 0.5 { board.scroll(to: CGPoint(x: 0, y: t), instant: instant) }
        }
    }

    /// ⌥⌘← / ⌥⌘→ move the selected card one place (not in history, which stays by date).
    private func moveSelected(by d: Int) {
        guard model.mode != .history, let id = model.selectedID, let i = model.selectedIndex,
              model.clips.indices.contains(i + d) else { return }
        store.move(id: id, toIndex: i + d)
        if stale { reload() }
        scrollToSelection()
    }

    private func cycleFocus(_ d: Int) {
        guard let id = model.selectedID else { return }
        var zones: [FocusZone] = [.card]
        if !model.missing.contains(id) { zones.append(.copy) }
        zones.append(.remove)
        if historyEnabled { zones.append(.history) }
        let i = zones.firstIndex(of: model.focus) ?? 0
        model.focus = zones[(i + d + zones.count) % zones.count]
        content.topBar.history.focused = model.focus == .history
    }

    private func activateFocus() {
        if model.focus == .history {
            toggleHistory()
            return
        }
        guard let id = model.selectedID else { return }
        switch model.focus {
        case .card: paste(id)
        case .copy: copy(id)
        case .remove: remove(id)
        case .history: break
        }
    }

    // MARK: Actions

    func clip(_ id: UUID) -> Clip? { model.clips.first { $0.id == id } }

    /// An image clip whose file has gone is disabled: it can only be removed.
    private func isUsable(_ clip: Clip) -> Bool {
        if model.missing.contains(clip.id) { return false }
        guard clip.kind == .image else { return true }
        if let url = clip.imageURL, FileManager.default.fileExists(atPath: url.path) { return true }
        model.markMissing(clip.id)
        return false
    }

    /// Paste: order the panel out, hand focus back to the app you were in, write the clip,
    /// then send ⌘V once that app is active. Without permission, or under Secure Input,
    /// the clip stays on the clipboard and a toast says so.
    private func paste(_ id: UUID) {
        guard let clip = clip(id), isUsable(clip) else { return }
        if let intercept = pasteInterceptor {
            intercept(id)
            if interceptedPasteCloses { close() }
            return
        }
        let started = CACurrentMediaTime()
        let target = previousApp
        let screen = self.screen
        close()
        if let target, !target.isTerminated, !target.isActive { target.activate() }
        guard let count = Paster.write(clip) else { return }
        watcher.markOwnWrite(changeCount: count)
        guard Paster.canPost else {
            Paster.promptOnce()
            showToast(on: screen)
            return
        }
        guard let target, !target.isTerminated, !Paster.secureInputOn else {
            showToast(on: screen)
            return
        }
        Task { [weak self] in
            var waited = 0
            while !target.isActive && waited < 500 {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 10
            }
            guard target.isActive else {
                self?.showToast(on: screen)
                return
            }
            // A beat for the app's window to take the keyboard back from the panel.
            try? await Task.sleep(for: .milliseconds(30))
            // If the leaving panel kept the keyboard, the ⌘V would land in it: order it out now.
            if let self, self.panel.isKeyWindow {
                self.cutExit()
                appLog("paste: the panel still had the keyboard; ordered out before ⌘V")
                debugLog("paste: the panel still had the keyboard; ordered out before ⌘V")
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard !Paster.secureInputOn else {
                self?.showToast(on: screen)
                return
            }
            Paster.postCommandV()
            debugLog("paste: ⌘V sent \(Int((CACurrentMediaTime() - started) * 1000)) ms after the pick")
        }
    }

    /// Copy keeps the panel open; the button shows a checkmark for 1.5 s.
    private func copy(_ id: UUID) {
        guard let clip = clip(id), isUsable(clip) else { return }
        if let count = Paster.write(clip) {
            watcher.markOwnWrite(changeCount: count)
            model.marks[id] = .done
        } else {
            model.marks[id] = .failed
        }
        let token = UUID()
        markTokens[id] = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.markTokens[id] == token else { return }
            self.markTokens[id] = nil
            self.model.marks[id] = nil
        }
    }

    /// The selection moves to the right neighbour, or the left one if the card was last.
    /// The neighbours close the gap on `settle`.
    func remove(_ id: UUID) {
        guard let i = model.clips.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = model.selectedID == id
        store.remove(id: id)
        if stale { reload() }
        model.marks[id] = nil
        model.missing.remove(id)
        if wasSelected, !model.clips.isEmpty { selectIndex(min(i, model.clips.count - 1)) }
        refreshHover()
    }

    func showToast(on screen: NSScreen?) {
        toast.show(Self.toastText, on: screen, material: material, increaseContrast: model.theme.increaseContrast)
    }

    // MARK: Debug

    /// `--demo-states`: shows hover, a pressed card, a confirmed copy and Tab focus at once.
    private func applyDemoStates() {
        let c = model.clips
        guard c.count >= 4 else { return }
        model.setHover(c[2].id, .remove)
        model.marks[c[2].id] = .done
        model.setPressed(c[3].id, nil)
        model.focus = .copy
    }

    private func logOpen(ms: Double) {
        guard DebugFlags.logGeometry, let screen else { return }
        let g = model.geometry, vf = screen.visibleFrame
        debugLog("open took \(String(format: "%.1f", ms)) ms; key \(panel.isKeyWindow); front app \(previousApp?.localizedName ?? "none")")
        debugLog("screen \(screen.frame) visible \(vf) scale \(screen.backingScaleFactor)")
        debugLog("window \(panel.frame); glass on screen \(glassScreenRect)")
        debugLog("panel height \(g.height) = screen height \(Int(screen.frame.height)) ÷ 6 → \(Int(screen.frame.height) / 6); width \(g.width)")
        debugLog("cards \(g.cardWidth) × \(g.cardHeight), \(g.layout.count) across, gap \(CardLayout.gap), side padding \(g.sidePadding), lines \(g.lines), rows that fit \(g.grid.maxRows), heights \((1...g.grid.maxRows).map { g.grid.height(rows: $0) })")
        debugLog("clips \(model.clips.count); rows \(rows); mode \(model.mode); material \(material); theme \(model.theme)")
        for (i, r) in board.cellFrames(3).enumerated() {
            debugLog("card \(i) in the scroll content: x \(r.minX) y \(r.minY) w \(r.width) h \(r.height)")
        }
    }
}

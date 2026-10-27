import AppKit
import Carbon
import SwiftUI
import ClipnpasteCore

/// Owns the panel: built once at launch, then only ordered in and out. Routes every key and
/// click itself (SwiftUI only draws), and runs the paste path.
@MainActor
final class PanelController {
    private static let clipLimit = 200
    private static let classicBlurKey = "useClassicBlur"
    private static let toastText = "Copied. Press ⌘V to paste."

    private let store: any ClipStore
    private let watcher: any ClipboardWatcher
    private let panel = ClipPanel()
    private let root = PanelRootView()
    private let model: PanelModel
    private let surface: GlassSurface
    private let toast = Toast()
    private var storeToken: UUID?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var stale = true
    private var screen: NSScreen?
    /// The app that was in front when the panel opened; the paste goes there.
    private var previousApp: NSRunningApplication?
    private var press: Press?
    /// Copied clips move to the front the next time the panel opens.
    private var pendingBumps: [UUID] = []
    private var markTokens: [UUID: UUID] = [:]
    private weak var scrollView: NSScrollView?

    private(set) var isOpen = false

    private struct Press {
        let id: UUID
        let button: CardButton?
        let start: NSPoint
        var moved = false
    }

    private enum Hit {
        case outside, panel
        case card(Int)
        case button(Int, CardButton)
    }

    var useClassicBlur: Bool {
        get { UserDefaults.standard.bool(forKey: Self.classicBlurKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.classicBlurKey)
            applyDisplayOptions()
        }
    }

    private var material: GlassSurface.Material {
        guard useClassicBlur else { return .glass }
        return model.theme.reduceTransparency ? .opaque : .classic
    }

    init(store: any ClipStore, watcher: any ClipboardWatcher) {
        self.store = store
        self.watcher = watcher
        let model = PanelModel()
        self.model = model
        let hosting = NSHostingView(rootView: PanelView(model: model))
        hosting.sizingOptions = []
        surface = GlassSurface(content: hosting, cornerRadius: PanelGeometry.radius, material: .glass)

        root.wantsLayer = true
        root.addSubview(surface)
        panel.contentView = root
        panel.router = { [unowned self] in self.route($0) }
        panel.onResignKey = { [unowned self] in self.close() }
        root.onMouseMoved = { [unowned self] in self.hover(at: $0) }
        root.onMouseExited = { [unowned self] in self.hover(at: nil) }
        model.onScroll = { [unowned self] in self.refreshHover() }
        model.onOpenSettings = { [unowned self] in
            self.close()
            Paster.openAccessibilitySettings()
        }
        storeToken = store.addObserver { [weak self] _ in self?.storeChanged() }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.applyDisplayOptions() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } })

        // One layout pass now, off screen, so the first open has nothing to build.
        applyDisplayOptions()
        layout(on: mouseScreen())
        reload()
        root.layoutSubtreeIfNeeded()
    }

    // MARK: Open and close

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard !isOpen else { return }
        let started = CACurrentMediaTime()
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        applyPendingBumps()
        layout(on: mouseScreen())
        applyDisplayOptions()
        model.now = Date()
        model.marks = [:]
        markTokens = [:]
        reload()
        model.selectedID = model.clips.first?.id
        model.focus = .card
        model.needsAccessibility = !Paster.canPost
        model.scrollPosition.scrollTo(x: 0)
        model.scrollX = 0

        isOpen = true
        panel.orderFrontRegardless()
        panel.makeKey()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        refreshHover()
        if DebugFlags.demoStates { applyDemoStates() }
        logOpen(ms: (CACurrentMediaTime() - started) * 1000)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        press = nil
        model.setPressed(nil, nil)
        model.setHover(nil, nil)
        panel.orderOut(nil)
    }

    private func mouseScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Sizes the window from the screen's visible frame, read fresh on every open.
    private func layout(on screen: NSScreen?) {
        guard let screen else { return }
        self.screen = screen
        let vf = screen.visibleFrame
        let g = PanelGeometry(visibleWidth: Int(vf.width), visibleHeight: Int(vf.height))
        if g != model.geometry { model.geometry = g }
        let inset = CGFloat(PanelGeometry.inset)
        let frame = NSRect(x: vf.minX.rounded(.down), y: vf.minY.rounded(.down), width: CGFloat(Int(vf.width)),
                           height: inset + CGFloat(g.height + PanelGeometry.shadowRoom))
        panel.setFrame(frame, display: false)
        surface.frame = NSRect(x: inset, y: inset, width: CGFloat(g.width), height: CGFloat(g.height))
    }

    private func applyDisplayOptions() {
        let ws = NSWorkspace.shared
        model.theme = Theme(
            increaseContrast: DebugFlags.increaseContrast || ws.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: DebugFlags.reduceTransparency || ws.accessibilityDisplayShouldReduceTransparency,
            reduceMotion: DebugFlags.reduceMotion || ws.accessibilityDisplayShouldReduceMotion)
        surface.material = material
        surface.increaseContrast = model.theme.increaseContrast
    }

    // MARK: Clips

    private func storeChanged() {
        if isOpen { reload() } else { stale = true }
    }

    private func reload() {
        stale = false
        let clips = store.ordered(Self.clipLimit)
        model.clips = clips
        let ids = Set(clips.map(\.id))
        if let sel = model.selectedID, !ids.contains(sel) { model.selectedID = nil }
        if model.selectedID == nil {
            model.selectedID = clips.first?.id
            model.focus = .card
        }
    }

    private func applyPendingBumps() {
        guard !pendingBumps.isEmpty else { return }
        let clips = store.ordered(Self.clipLimit)
        for id in pendingBumps {
            guard var clip = clips.first(where: { $0.id == id }) else { continue }
            clip.createdAt = Date()
            store.insertOrBump(clip)
        }
        pendingBumps = []
    }

    // MARK: Events

    private func route(_ event: NSEvent) -> NSEvent? {
        guard isOpen else { return event }
        switch event.type {
        case .keyDown:
            handleKey(event)
            return nil
        case .leftMouseDown:
            return mouseDown(event)
        case .leftMouseDragged:
            return press == nil ? event : mouseDragged(event)
        case .leftMouseUp:
            return press == nil ? event : mouseUp(event)
        case .rightMouseDown, .otherMouseDown:
            if case .outside = hit(event.locationInWindow) { close() }
            return nil
        case .scrollWheel:
            guard let sideways = Self.wheelAsSideways(event), let scroll = rowScrollView() else { return event }
            scroll.scrollWheel(with: sideways)
            return nil
        default:
            return event
        }
    }

    private func handleKey(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command), opt = flags.contains(.option), ctrl = flags.contains(.control)
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
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !e.isARepeat { activateFocus() }
        case kVK_Space:
            if model.focus != .card, !e.isARepeat { activateFocus() }
        case kVK_Tab:
            cycleFocus(flags.contains(.shift) ? -1 : 1)
        case kVK_Delete, kVK_ForwardDelete:
            if let id = model.selectedID { remove(id) }
        default:
            if cmd, !ctrl, !opt, e.charactersIgnoringModifiers?.lowercased() == "c", let id = model.selectedID {
                copy(id)
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
        case .card(let i):
            let id = model.clips[i].id
            press = Press(id: id, button: nil, start: p)
            model.setPressed(id, nil)
            return nil
        case .button(let i, let b):
            let id = model.clips[i].id
            if b == .copy, model.missing.contains(id) { return nil }
            press = Press(id: id, button: b, start: p)
            model.setPressed(id, b)
            return nil
        }
    }

    private func mouseDragged(_ event: NSEvent) -> NSEvent? {
        guard var p = press else { return event }
        let loc = event.locationInWindow
        if p.button == nil, !p.moved, hypot(loc.x - p.start.x, loc.y - p.start.y) >= 4 {
            // Drag-out starts here (day 2). Until then a press that moves is cancelled.
            p.moved = true
            press = p
            model.setPressed(nil, nil)
        }
        return nil
    }

    private func mouseUp(_ event: NSEvent) -> NSEvent? {
        guard let p = press else { return event }
        press = nil
        model.setPressed(nil, nil)
        if let b = p.button {
            if case .button(let i, let upOn) = hit(event.locationInWindow), upOn == b, model.clips[i].id == p.id {
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

    /// The row's scroll view inside the SwiftUI content. The swapped wheel event goes straight
    /// to it, since an event rebuilt from a CGEvent no longer knows which window it was in.
    private func rowScrollView() -> NSScrollView? {
        if let s = scrollView, s.window != nil { return s }
        func search(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView { return s }
            for sub in v.subviews { if let s = search(sub) { return s } }
            return nil
        }
        scrollView = search(surface.content)
        return scrollView
    }

    /// What is under a point in window coordinates. Cards sit at fixed whole-point positions,
    /// so this is plain arithmetic on the layout and the scroll offset.
    private func hit(_ p: NSPoint) -> Hit {
        let g = model.geometry
        let f = surface.frame
        guard f.contains(p) else { return .outside }
        let x = p.x - f.minX, y = f.maxY - p.y
        let cy = y - CGFloat(g.cardTop)
        guard !model.clips.isEmpty, cy >= 0, cy < CGFloat(g.cardHeight) else { return .panel }
        let cx = x + model.scrollX - CGFloat(g.sidePadding)
        guard cx >= 0 else { return .panel }
        let i = Int(cx / CGFloat(g.pitch))
        let lx = cx - CGFloat(i * g.pitch)
        guard i < model.clips.count, lx < CGFloat(g.cardWidth) else { return .panel }
        // 20 pt buttons, 6 pt from the right edge and 4 pt apart, centred in the 26 pt header.
        if cy >= 3, cy < 23 {
            let right = CGFloat(g.cardWidth - 6)
            if lx >= right - 20, lx < right { return .button(i, .remove) }
            if lx >= right - 44, lx < right - 24 { return .button(i, .copy) }
        }
        return .card(i)
    }

    private func hover(at p: NSPoint?) {
        guard isOpen, press == nil else { return }
        guard let p else { return model.setHover(nil, nil) }
        switch hit(p) {
        case .card(let i): model.setHover(model.clips[i].id, nil)
        case .button(let i, let b): model.setHover(model.clips[i].id, b)
        default: model.setHover(nil, nil)
        }
    }

    private func refreshHover() {
        guard isOpen else { return }
        hover(at: panel.convertPoint(fromScreen: NSEvent.mouseLocation))
    }

    // MARK: Selection and focus

    private func step(_ d: Int) {
        guard !model.clips.isEmpty else { return }
        let i = model.selectedIndex.map { $0 + d } ?? 0
        selectIndex(min(max(i, 0), model.clips.count - 1))
    }

    private func selectIndex(_ i: Int) {
        guard model.clips.indices.contains(i) else { return }
        select(model.clips[i].id)
    }

    private func select(_ id: UUID) {
        if model.selectedID != id { model.selectedID = id }
        if model.focus != .card { model.focus = .card }
        scrollToSelection()
    }

    /// Keeps the selected card in view with one card of margin.
    private func scrollToSelection() {
        guard let i = model.selectedIndex else { return }
        let g = model.geometry
        let x = CGFloat(g.cardX(i)), cw = CGFloat(g.cardWidth), m = CGFloat(g.pitch)
        let pad = CGFloat(g.sidePadding), w = CGFloat(g.width)
        let current = model.scrollX
        var target = current
        if x - m < current + pad {
            target = x - m - pad
        } else if x + cw + m > current + w - pad {
            target = x + cw + m - w + pad
        }
        target = min(max(target, 0), g.maxScroll(count: model.clips.count))
        guard abs(target - current) > 0.5 else { return }
        model.scrollPosition.scrollTo(x: target)
        model.scrollX = target
        refreshHover()
    }

    /// ⌥⌘← / ⌥⌘→ move the selected card one place.
    private func moveSelected(by d: Int) {
        guard let id = model.selectedID, let i = model.selectedIndex, model.clips.indices.contains(i + d) else { return }
        store.move(id: id, toIndex: i + d)
        if stale { reload() }
        scrollToSelection()
    }

    private func cycleFocus(_ d: Int) {
        guard let id = model.selectedID else { return }
        var zones: [FocusZone] = [.card]
        if !model.missing.contains(id) { zones.append(.copy) }
        zones.append(.remove)
        let i = zones.firstIndex(of: model.focus) ?? 0
        model.focus = zones[(i + d + zones.count) % zones.count]
    }

    private func activateFocus() {
        guard let id = model.selectedID else { return }
        switch model.focus {
        case .card: paste(id)
        case .copy: copy(id)
        case .remove: remove(id)
        }
    }

    // MARK: Actions

    private func clip(_ id: UUID) -> Clip? { model.clips.first { $0.id == id } }

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
            if !pendingBumps.contains(id) { pendingBumps.append(id) }
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
    private func remove(_ id: UUID) {
        guard let i = model.clips.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = model.selectedID == id
        store.remove(id: id)
        if stale { reload() }
        model.marks[id] = nil
        model.missing.remove(id)
        if wasSelected, !model.clips.isEmpty { selectIndex(min(i, model.clips.count - 1)) }
        refreshHover()
    }

    private func showToast(on screen: NSScreen?) {
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
        let glass = panel.convertToScreen(surface.convert(surface.bounds, to: nil))
        debugLog("open took \(String(format: "%.1f", ms)) ms; key \(panel.isKeyWindow); front app \(previousApp?.localizedName ?? "none")")
        debugLog("screen \(screen.frame) visible \(vf) scale \(screen.backingScaleFactor)")
        debugLog("window \(panel.frame); glass on screen \(glass)")
        debugLog("panel height \(g.height) = visible height \(Int(vf.height)) ÷ 6 → \(Int(vf.height) / 6); width \(g.width)")
        debugLog("cards \(g.cardWidth) × \(g.cardHeight), \(g.layout.count) across, gap \(CardLayout.gap), side padding \(g.sidePadding), lines \(g.lines), rows that fit \(g.layout.rows(forHeight: g.visibleHeight - 2 * PanelGeometry.inset))")
        debugLog("clips \(model.clips.count); material \(material); theme \(model.theme)")
        for other in NSScreen.screens where other != screen {
            let v = other.visibleFrame, o = PanelGeometry(visibleWidth: Int(v.width), visibleHeight: Int(v.height))
            debugLog("on \(Int(other.frame.width))×\(Int(other.frame.height)) (visible \(Int(v.width))×\(Int(v.height))): panel \(o.width)×\(o.height), cards \(o.cardWidth)×\(o.cardHeight), \(o.layout.count) across, side padding \(o.sidePadding), lines \(o.lines)")
        }
    }

    /// `--self-test`: drives the panel's own event router with synthetic keys, a wheel notch and
    /// a click, and logs the result of each. Nothing is posted to the system and nothing is
    /// pasted or copied, so the clipboard is untouched.
    func runSelfTest() async {
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "") {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: panel.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)) {
                panel.sendEvent(e)
            }
        }
        func click(_ p: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                                              windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 1) {
                    panel.sendEvent(e)
                }
            }
        }
        func report(_ step: String) {
            let first = model.clips.first?.plainText?.prefix(12) ?? "-"
            debugLog("self-test \(step): selected \(model.selectedIndex ?? -1) of \(model.clips.count), focus \(model.focus), scrollX \(model.scrollX), first \"\(first)\", open \(isOpen)")
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
        let g = model.geometry
        await settle()
        report("opened")
        for _ in 0..<3 { key(kVK_RightArrow) }
        report("→ ×3 (expect 3)")
        key(kVK_RightArrow, .command); await settle()
        report("⌘→ (expect last, scrolled to max \(g.maxScroll(count: model.clips.count)))")
        key(kVK_LeftArrow, .command); await settle()
        report("⌘← (expect 0, scroll 0)")
        let firstID = model.clips.first?.id
        key(kVK_RightArrow, [.command, .option]); await settle()
        report("⌥⌘→ (expect selected 1, moved card now at 1: \(model.clips.firstIndex { $0.id == firstID } ?? -1))")
        key(kVK_Tab); report("Tab (expect copy)")
        key(kVK_Tab); report("Tab (expect remove)")
        key(kVK_Tab); report("Tab (expect card)")
        key(kVK_Tab, .shift); report("⇧Tab (expect remove)")
        let count = model.clips.count
        key(kVK_Return); await settle()
        report("Return on Remove (expect \(count - 1) clips, selected 1, focus card)")
        key(kVK_Delete); await settle()
        report("Delete (expect \(count - 2) clips, selected 1)")
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0),
           let wheel = NSEvent(cgEvent: cg) {
            _ = route(wheel)
            try? await Task.sleep(for: .milliseconds(600))
            report("mouse wheel 3 notches down (expect scrollX > 0)")
        }
        model.scrollPosition.scrollTo(x: 0); model.scrollX = 0; await settle()
        let remove = NSPoint(x: surface.frame.minX + CGFloat(g.sidePadding + g.cardWidth - 16),
                             y: surface.frame.maxY - CGFloat(g.cardTop + 13))
        click(remove); await settle()
        report("click on card 0's Remove (expect \(count - 3) clips)")
        key(kVK_Escape)
        report("Esc (expect open false)")
        showToast(on: screen)
        debugLog("toast shown at \(toast.frame) on visible \(screen?.visibleFrame ?? .zero)")
    }
}

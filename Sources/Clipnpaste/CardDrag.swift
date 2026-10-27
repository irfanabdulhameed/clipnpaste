import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClipnpasteCore

/// A card being dragged: lifted into its own small window that follows the pointer and tilts,
/// reordered inside the panel, or carried out to another app through a real drag session.
@MainActor
final class CardDrag {
    enum Phase { case drag, session, landing, done }

    let id: UUID
    let clip: Clip
    /// Its index in the panel when it was lifted.
    let from: Int
    /// The slot under the pointer; where it lands if released over the panel.
    var slot: Int
    /// History stays by copy date, so cards there only drag out.
    let reorderable: Bool
    /// Where it was grabbed, from the card's top-left (y down).
    let grab: CGPoint
    var pointer: NSPoint
    var velocity = VelocityTracker()
    var over = true
    var phase: Phase = .drag
    let preview: DragPreview
    var hook: Int?
    var session: NSDraggingSession?

    init(clip: Clip, from: Int, reorderable: Bool, grab: CGPoint, pointer: NSPoint, preview: DragPreview) {
        id = clip.id
        self.clip = clip
        self.from = from
        slot = from
        self.reorderable = reorderable
        self.grab = grab
        self.pointer = pointer
        self.preview = preview
    }
}

/// The drag preview: a borderless window that ignores the mouse, holding a copy of the card.
/// It moves with the pointer every display frame and tilts, scales and casts its shadow with Core
/// Animation, pivoting at the point you grabbed. The system's own drag image is left empty.
@MainActor
final class DragPreview: MotionTarget {
    static let margin: CGFloat = 150

    let window: NSPanel
    private let card: NSView
    let size: CGSize
    let grab: CGPoint
    /// The card's top-left on screen (x, top edge y).
    let px: Anim, py: Anim
    /// Degrees; negative is counter-clockwise (the top leans left).
    let rot: Anim
    let sc: Anim
    /// 0 → 1: the shadow grows from resting to lifted.
    let lift: Anim
    let op: Anim

    init(clip: Clip, model: PanelModel, frame: NSRect, grab: CGPoint) {
        size = frame.size
        self.grab = grab
        let m = Self.margin
        window = NSPanel(contentRect: NSRect(x: frame.minX - m, y: frame.minY - m, width: size.width + 2 * m, height: size.height + 2 * m),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        let root = NSView()
        root.wantsLayer = true
        window.contentView = root
        card = NSView(frame: NSRect(x: m, y: m, width: size.width, height: size.height))
        card.wantsLayer = true
        let host = NSHostingView(rootView: CardView(clip: clip, state: CardState(), geometry: model.geometry, theme: model.theme,
                                                    now: model.now, preview: true))
        host.sizingOptions = []
        host.frame = card.bounds
        card.addSubview(host)
        root.addSubview(card)
        if let l = card.layer {
            l.masksToBounds = false
            l.shadowColor = NSColor.black.cgColor
            l.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: PanelGeometry.cardRadius,
                                  cornerHeight: PanelGeometry.cardRadius, transform: nil)
        }
        px = Anim(frame.minX, owner: nil, eps: 0.05)
        py = Anim(frame.maxY, owner: nil, eps: 0.05)
        rot = Anim(0, owner: nil, eps: 0.01)
        sc = Anim(1, owner: nil, eps: 0.0005)
        lift = Anim(0, owner: nil, eps: 0.002)
        op = Anim(1, owner: nil, eps: 0.002)
        for a in [px, py, rot, sc, lift, op] { a.owner = self }
        render()
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.orderFrontRegardless()
    }

    /// The card's untransformed rect on screen.
    var cardFrame: NSRect { NSRect(x: px.v, y: py.v - size.height, width: size.width, height: size.height) }

    func render() {
        let m = Self.margin
        let origin = NSPoint(x: (CGFloat(px.v) - m).rounded(), y: (CGFloat(py.v) - size.height - m).rounded())
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
        guard let l = card.layer else { return }
        // Pivot at the grab point; the layer is y-up, its anchor wherever AppKit put it.
        let a = l.anchorPoint
        let p = CGPoint(x: grab.x - a.x * size.width, y: (size.height - grab.y) - a.y * size.height)
        var t = CATransform3DMakeTranslation(-p.x, -p.y, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(CGFloat(sc.v), CGFloat(sc.v), 1))
        t = CATransform3DConcat(t, CATransform3DMakeRotation(CGFloat(-rot.v * .pi / 180), 0, 0, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(p.x, p.y, 0))
        l.transform = t
        // From the prototype: offset 4 → 14 pt down, blur 4 → 12 (a CSS blur, so radius / 2), 14% → 28%.
        let k = min(max(lift.v, 0), 1.2)
        l.shadowOffset = CGSize(width: 0, height: -(4 + 10 * k))
        l.shadowRadius = (4 + 8 * k) / 2
        l.shadowOpacity = Float(0.14 + 0.14 * k)
        window.alphaValue = CGFloat(min(max(op.v, 0), 1))
    }

    func close() {
        for a in [px, py, rot, sc, lift, op] { a.stop() }
        window.orderOut(nil)
        window.close()
    }
}

/// Receives the drag session's callbacks for the panel.
@MainActor
final class DragSource: NSObject, NSDraggingSource {
    weak var controller: PanelController?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        controller?.sessionMoved(to: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.sessionEnded(at: screenPoint, operation: operation)
    }
}

/// What a dragged card carries. Text: the plain string plus RTF and HTML when stored, so text
/// fields and rich editors both take it. Image: a file URL to a named PNG copy plus PNG and TIFF
/// data, made only when an app asks for them.
@MainActor
enum DragPasteboard {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Clipnpaste Drags", isDirectory: true)
    private static var providers: [ImageDataProvider] = []

    static func item(for clip: Clip) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        switch clip.kind {
        case .text:
            guard let text = clip.plainText else { return nil }
            item.setString(text, forType: .string)
            if let rtf = clip.rtfData { item.setData(rtf, forType: .rtf) }
            if let html = clip.htmlData { item.setData(html, forType: .html) }
        case .image:
            guard let src = clip.imageURL, FileManager.default.fileExists(atPath: src.path) else { return nil }
            let file = namedCopy(of: src, date: clip.createdAt) ?? src
            item.setString(file.absoluteString, forType: .fileURL)
            let provider = ImageDataProvider(url: src)
            item.setDataProvider(provider, forTypes: [.png, .tiff])
            providers = [provider]
        }
        item.setString(Bundle.main.bundleIdentifier ?? "com.irfanabdulhameed.clipnpaste", forType: Paster.sourceType)
        return item
    }

    /// "Clip 27 Oct 2026 at 14.03.png" in a temporary folder, a clone of the stored file.
    private static func namedCopy(of src: URL, date: Date) -> URL? {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy 'at' HH.mm"
        let dest = folder.appendingPathComponent("Clip \(f.string(from: date)).png")
        guard (try? fm.copyItem(at: src, to: dest)) != nil else { return nil }
        return dest
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The drag session gets no image: the follower window is the preview.
    static let clearImage: NSImage = {
        let i = NSImage(size: NSSize(width: 1, height: 1))
        i.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        i.unlockFocus()
        return i
    }()
}

/// Reads the clip's PNG (and makes TIFF from it) only when the drop target asks.
final class ImageDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let url: URL

    init(url: URL) { self.url = url }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let png = try? Data(contentsOf: url) else { return }
        if type == .png {
            item.setData(png, forType: .png)
        } else if type == .tiff, let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
    }
}

extension PanelController {
    // MARK: Lift

    /// Past the 4 pt threshold: the preview window appears exactly over the card (it is the card),
    /// the card flips to a 35% ghost, and the preview lifts: scale 1.04 and the shadow on `quick`,
    /// the −6° tilt on `settle`, then ±8° more from horizontal speed on `track`, every frame.
    func liftDrag(_ clip: Clip, grabbedAt start: NSPoint, event: NSEvent) {
        guard let from = model.clips.firstIndex(where: { $0.id == clip.id }),
              let docRect = board.currentRect(clip.id) else { return }
        press = nil
        let screenRect = screenRect(ofContent: docRect)
        let startScreen = panel.convertPoint(toScreen: start)
        let grab = CGPoint(x: startScreen.x - screenRect.minX, y: screenRect.maxY - startScreen.y)
        let preview = DragPreview(clip: clip, model: model, frame: screenRect, grab: grab)
        // It lifts from the card's pressed size, so the lift never jumps.
        let pressed = board.scale(of: clip.id)
        if abs(pressed - 1) > 1e-4 {
            preview.sc.set(pressed)
            preview.render()
        }
        let d = CardDrag(clip: clip, from: from, reorderable: model.mode != .history, grab: grab,
                         pointer: startScreen, preview: preview)
        d.velocity.add(time: ProcessInfo.processInfo.systemUptime, x: startScreen.x, y: startScreen.y)
        drag = d
        model.setHover(nil, nil)
        model.setPressed(nil, nil)
        board.ghostID = clip.id
        panel.ignoresMouseEvents = false
        if Motion.reduce {
            preview.lift.set(1)
        } else {
            preview.sc.spring(to: 1.04, duration: Motion.quick)
            preview.lift.spring(to: 1, duration: Motion.quick)
            preview.rot.spring(to: DragTilt.lift, duration: Motion.settle)
        }
        d.hook = MotionClock.shared.addHook { [weak self, weak d] dt in
            guard let self, let d else { return }
            self.dragFrame(d, dt: dt)
        }
        debugLog("drag: lifted card \(from) at \(Int(screenRect.minX)),\(Int(screenRect.minY)) \(Int(screenRect.width))×\(Int(screenRect.height)), grabbed at \(Int(grab.x)),\(Int(grab.y))")
        dragMoved(d, to: panel.convertPoint(toScreen: event.locationInWindow), time: event.timestamp)
    }

    /// Every display frame while the card is held: follow the pointer, tilt from its speed,
    /// scroll near the row's edges.
    private func dragFrame(_ d: CardDrag, dt: Double) {
        guard d.phase == .drag || d.phase == .session else { return }
        if d.phase == .session {
            let p = NSEvent.mouseLocation
            if p != d.pointer { dragMoved(d, to: p, time: ProcessInfo.processInfo.systemUptime) }
        }
        if !Motion.reduce {
            let v = d.velocity.velocity(at: ProcessInfo.processInfo.systemUptime)
            d.preview.rot.spring(to: DragTilt.angle(velocityX: v.x), duration: Motion.track)
        }
        autoScroll(d, dt: dt)
    }

    private func autoScroll(_ d: CardDrag, dt: Double) {
        guard d.reorderable, d.over, strip == .full, model.mode != .history else { return }
        let g = glassScreenRect
        let speed: Double
        if model.mode == .row {
            speed = AutoScroll.speed(position: d.pointer.x, lower: g.minX, upper: g.maxX)
        } else {
            // Screen y grows upward; the scroll area runs from 22 pt below the glass top to its bottom.
            speed = AutoScroll.speed(position: g.maxY - CGFloat(PanelGrid.scrollTop) - d.pointer.y,
                                     lower: 0, upper: g.height - CGFloat(PanelGrid.scrollTop))
        }
        guard speed != 0 else { return }
        let v = board.viewport.origin, m = board.maxScroll
        let next = model.mode == .row
            ? CGPoint(x: min(max(v.x + speed * dt, 0), m.x), y: v.y)
            : CGPoint(x: v.x, y: min(max(v.y + speed * dt, 0), m.y))
        guard next != v else { return }
        board.scroll(to: next, instant: true)
        updateSlot(d)
    }

    // MARK: Moving

    /// Inside the panel the window's own mouse events drive the drag; leaving the panel starts
    /// the real drag session other apps can take a drop from.
    func dragDragged(_ d: CardDrag, _ event: NSEvent) {
        dragMoved(d, to: panel.convertPoint(toScreen: event.locationInWindow), time: event.timestamp)
        if !d.over, d.session == nil, !DebugFlags.drivesPanel {
            startSession(d, event)
        }
    }

    func dragMoved(_ d: CardDrag, to p: NSPoint, time: Double) {
        d.pointer = p
        d.velocity.add(time: time > 0 ? time : ProcessInfo.processInfo.systemUptime, x: p.x, y: p.y)
        if d.phase == .drag || d.phase == .session {
            // Follows the pointer exactly, no smoothing.
            d.preview.px.set(p.x - d.grab.x)
            d.preview.py.set(p.y + d.grab.y)
        }
        let over = overPanel(p)
        if over != d.over {
            debugLog("drag: \(over ? "back over" : "left") the panel at \(Int(p.x)),\(Int(p.y)); glass \(glassScreenRect)")
            d.over = over
            zoneChanged(d)
        }
        if d.phase == .session { panel.ignoresMouseEvents = !overPanelWindow(p) }
        updateSlot(d)
    }

    /// Over the glass, or (as a strip) over the strip and 24 pt above it.
    func overPanel(_ p: NSPoint) -> Bool {
        let g = glassScreenRect
        guard p.x >= g.minX, p.x <= g.maxX else { return false }
        if strip == .strip { return p.y <= g.minY + CGFloat(PanelGrid.stripHeight) + 24 }
        return p.y <= g.minY + CGFloat(glass.h.dest)
    }

    /// The window takes the drop only over the glass; elsewhere drops go to the apps below.
    private func overPanelWindow(_ p: NSPoint) -> Bool {
        glassScreenRect.insetBy(dx: 0, dy: strip == .strip ? -12 : 0).contains(p)
    }

    private func zoneChanged(_ d: CardDrag) {
        let rm = Motion.reduce
        if d.over {
            exitStrip()
            if rm { d.preview.sc.set(1) } else { d.preview.sc.spring(to: 1.04, duration: Motion.quick) }
        } else {
            // Its old slot is kept for it while it is away.
            if d.slot != d.from {
                d.slot = d.from
                layoutBoard(.reflow)
            }
            enterStrip()
            if rm { d.preview.sc.set(0.7) } else { d.preview.sc.spring(to: 0.7, duration: Motion.quick) }
        }
    }

    /// The others part on `settle` to open the slot under the pointer.
    private func updateSlot(_ d: CardDrag) {
        guard d.reorderable, d.over, strip == .full, d.phase == .drag || d.phase == .session else { return }
        let f = surface.frame
        let w = panel.convertPoint(fromScreen: d.pointer)
        let v = board.viewport
        let docX = w.x - f.minX + v.minX - d.grab.x
        let docY = f.maxY - w.y - CGFloat(PanelGrid.scrollTop) + v.minY - d.grab.y
        let s = model.geometry.grid.slot(cardX: docX, cardY: docY, grid: model.mode == .grid, count: model.clips.count)
        guard s != d.slot else { return }
        d.slot = s
        layoutBoard(.reflow)
    }

    // MARK: Session

    private func startSession(_ d: CardDrag, _ event: NSEvent) {
        guard let item = DragPasteboard.item(for: d.clip) else { return }
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let p = root.convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: p.x, y: p.y, width: 1, height: 1), contents: DragPasteboard.clearImage)
        let s = root.beginDraggingSession(with: [dragItem], event: event, source: dragSource)
        s.animatesToStartingPositionsOnCancelOrFail = false
        s.draggingFormation = .none
        d.session = s
        d.phase = .session
        debugLog("drag: session started for a \(d.clip.kind) clip")
    }

    func sessionMoved(to p: NSPoint) {
        guard let d = drag, d.phase == .session else { return }
        dragMoved(d, to: p, time: ProcessInfo.processInfo.systemUptime)
    }

    /// The session ended. A drop another app took: the preview shrinks away at the drop point and
    /// the panel grows back. Released over the panel or strip: it lands in the slot. Esc (the
    /// button is still down), a refused drop or a drop on nothing: it flies back.
    func sessionEnded(at p: NSPoint, operation: NSDragOperation) {
        guard let d = drag, d.phase == .session else { return }
        d.pointer = p
        panel.ignoresMouseEvents = false
        let cancelled = NSEvent.pressedMouseButtons & 1 != 0
        debugLog("drag: session ended, operation \(operation.rawValue), cancelled \(cancelled)")
        if !operation.isEmpty {
            dropAccepted(d)
        } else if !cancelled, overPanel(p) {
            land(d, reorder: true)
        } else {
            cancelDrag(d)
        }
        if !DebugFlags.drivesPanel { panel.makeKey() }
    }

    // MARK: Endings

    /// Released inside the panel without leaving it.
    func dragReleased(_ d: CardDrag, _ event: NSEvent) {
        dragMoved(d, to: panel.convertPoint(toScreen: event.locationInWindow), time: event.timestamp)
        if d.over { land(d, reorder: true) } else { cancelDrag(d) }
    }

    /// Esc, a refused drop or a drop on nothing: back to its old slot.
    func cancelDrag(_ d: CardDrag) {
        if d.slot != d.from {
            d.slot = d.from
            layoutBoard(.reflow)
        }
        land(d, reorder: false)
    }

    /// The preview settles into its slot on `arrive` (position, tilt to 0, scale to 1), starting
    /// from its current speed, while the panel grows back; the ghost flips to 100% as it lands,
    /// so the card is never shown twice.
    private func land(_ d: CardDrag, reorder: Bool) {
        let target = reorder && d.reorderable ? d.slot : d.from
        if !reorder || !d.reorderable, d.slot != d.from {
            d.slot = d.from
            layoutBoard(.reflow)
        }
        d.phase = .landing
        MotionClock.shared.removeHook(d.hook)
        d.hook = nil
        exitStrip()
        if target != d.from {
            // Into the store now; the cards already stand in this order, so nothing jumps.
            store.move(id: d.id, toIndex: target)
            if stale { reload() }
            debugLog("drag: placed card \(d.from) at \(target)")
        }
        let pv = d.preview
        if Motion.reduce {
            pv.op.tween(to: 0, ms: 120) { [weak self] in self?.finishDrag(d) }
            return
        }
        let v = d.velocity.velocity(at: ProcessInfo.processInfo.systemUptime)
        pv.px.spring(to: pv.px.v, duration: Motion.arrive, velocity: v.x)
        pv.py.spring(to: pv.py.v, duration: Motion.arrive, velocity: v.y)
        pv.rot.spring(to: 0, duration: Motion.arrive)
        pv.sc.spring(to: 1, duration: Motion.arrive)
        pv.lift.spring(to: 0, duration: Motion.arrive)
        let started = CACurrentMediaTime()
        d.hook = MotionClock.shared.addHook { [weak self, weak d] _ in
            guard let self, let d, d.phase == .landing, let r = self.board.currentRect(d.id) else { return }
            let s = self.screenRect(ofContent: r)
            pv.px.aim(s.minX)
            pv.py.aim(s.maxY)
            let near = abs(pv.px.v - s.minX) < 0.5 && abs(pv.py.v - s.maxY) < 0.5 && abs(pv.rot.v) < 0.3 && abs(pv.sc.v - 1) < 0.003
            if (near && !self.glass.h.busy) || CACurrentMediaTime() - started > 1.5 { self.finishDrag(d) }
        }
    }

    /// Another app took the drop: the preview shrinks 0.7 → 0.6 and fades on `leave` at the drop
    /// point, and the panel grows back so another card can be dragged.
    private func dropAccepted(_ d: CardDrag) {
        d.phase = .landing
        MotionClock.shared.removeHook(d.hook)
        d.hook = nil
        if d.slot != d.from {
            d.slot = d.from
            layoutBoard(.reflow)
        }
        board.ghostID = nil
        exitStrip()
        let pv = d.preview
        if Motion.reduce {
            pv.op.tween(to: 0, ms: 100) { [weak self] in self?.finishDrag(d) }
        } else {
            pv.sc.tween(to: pv.sc.v * (0.6 / 0.7), ms: 120, ease: Motion.leave)
            pv.op.tween(to: 0, ms: 120, ease: Motion.leave) { [weak self] in self?.finishDrag(d) }
        }
    }

    /// Every ending comes here: the follower window is destroyed and the ghost flips back.
    func finishDrag(_ d: CardDrag) {
        guard d.phase != .done else { return }
        d.phase = .done
        MotionClock.shared.removeHook(d.hook)
        d.hook = nil
        d.preview.close()
        if drag === d { drag = nil }
        if board.ghostID == d.id { board.ghostID = nil }
        if strip == .strip, isOpen { exitStrip() }
        fitWindow()
        refreshHover()
        debugLog("drag: finished; preview window closed")
    }

    // MARK: Geometry

    /// A rect in the scroll content, on screen.
    func screenRect(ofContent r: CGRect) -> NSRect {
        let f = surface.frame, v = board.viewport
        let x = f.minX + r.minX - v.minX
        let top = f.maxY - CGFloat(PanelGrid.scrollTop) - (r.minY - v.minY)
        return panel.convertToScreen(NSRect(x: x, y: top - r.height, width: r.width, height: r.height))
    }
}

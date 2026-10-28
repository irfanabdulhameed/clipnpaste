import AppKit
import ClipnpasteCore

/// The panel's life. `isOpen` is true while it opens or is open; a closing panel is still on
/// screen until its exit ends, and the shortcut then re-aims it instead of starting over.
enum PanelPhase: Sendable { case closed, opening, open, closing }

/// The glass's rise and exit: how far below its resting place it is and its opacity. Drawn as a
/// transform and opacity on the glass's own layer inside the pre-sized window; the window frame
/// never moves. Below the window's bottom edge (the top of the Dock, or the screen edge) the glass
/// is clipped, so it rises out of that edge.
@MainActor
final class RiseMotion: MotionTarget {
    unowned let controller: PanelController
    /// Points below the resting position: 0 at rest, H (glass height + 40) fully out of sight.
    let y: Anim
    let op: Anim
    /// The glass's scale: `materialiseScale` → 1 as it materialises, 1 at rest.
    let scale: Anim
    /// The travel of the open or close in progress.
    var travel: Double = 0
    /// Cards the exit blurred, reset when it ends.
    var blurred: [CardMotion] = []

    init(controller: PanelController) {
        self.controller = controller
        y = Anim(0, owner: nil, eps: 0.05)
        op = Anim(1, owner: nil, eps: 0.002)
        scale = Anim(1, owner: nil, eps: 0.0005)
        y.owner = self
        op.owner = self
        scale.owner = self
    }

    var busy: Bool { y.busy || op.busy || scale.busy }

    func render() { controller.renderRise() }
}

/// Opacity, blur and scale for one view (the empty-state message, the toast), as the
/// prototype's `Fx`: born blurred, and blurred out on the way.
@MainActor
final class Fx: MotionTarget {
    let op: Anim, blur: Anim, scale: Anim
    private let draw: (Fx) -> Void

    init(_ draw: @escaping (Fx) -> Void) {
        self.draw = draw
        op = Anim(1, owner: nil, eps: 0.002)
        blur = Anim(0, owner: nil, eps: 0.05)
        scale = Anim(1, owner: nil, eps: 0.0005)
        for a in [op, blur, scale] { a.owner = self }
    }

    var busy: Bool { op.busy || blur.busy || scale.busy }

    func render() { draw(self) }

    /// `blurBorn`: blur → 0 (and scale → 1) on a spring, opacity on `fadeIn` 140 ms; with
    /// `focus`, the open's slower focus instead (`focus` over `focusMs`, opacity over
    /// `focusFadeMs`). Under Reduce Motion it only fades, over 150 ms.
    func born(blur px: Double, duration: Double = Motion.settle, delay: Double = 0, scale s: Double = 1,
              focus: Bool = false) {
        if Motion.reduce {
            blur.set(0); scale.set(1)
            op.set(0); op.tween(to: 1, ms: 150, delay: delay)
            return
        }
        blur.set(px); scale.set(s); op.set(0)
        if focus {
            blur.tween(to: 0, ms: Motion.focusMs, ease: Motion.focus, delay: delay)
            if s != 1 { scale.tween(to: 1, ms: Motion.focusMs, ease: Motion.focus, delay: delay) }
            op.tween(to: 1, ms: Motion.focusFadeMs, ease: Motion.materialise, delay: delay)
            return
        }
        blur.spring(to: 0, duration: duration, delay: delay)
        if s != 1 { scale.spring(to: 1, duration: duration, delay: delay) }
        op.tween(to: 1, ms: 140, ease: Motion.fadeIn, delay: delay)
    }

    /// Back to rest at once: fully shown, sharp, no filter.
    func reset() {
        op.set(1); blur.set(0); scale.set(1)
    }
}

/// Layer helpers shared by the panel, the empty state and the toast.
@MainActor
enum LayerLook {
    /// A Gaussian blur of `px` points (the prototype's CSS blur), or no filter at all at 0, so
    /// everything at rest is pixel-crisp. Same scale as the cards' blur.
    static func blur(_ layer: CALayer?, _ px: Double, filter: inout CIFilter?) {
        guard let layer else { return }
        if px <= 0.05 {
            if layer.filters != nil { layer.filters = nil }
            return
        }
        let f = filter ?? CIFilter(name: "CIGaussianBlur")!
        f.setValue(px / 2, forKey: kCIInputRadiusKey)
        filter = f
        layer.filters = [f]
    }

    /// Scales a view's layer about the view's centre (AppKit anchors view layers at a corner).
    static func scale(_ view: NSView, _ s: Double) {
        guard let layer = view.layer else { return }
        let t = CardCell.scale(s, about: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
                               anchor: layer.anchorPoint, size: view.bounds.size)
        if !CATransform3DEqualToTransform(layer.transform, t) { layer.transform = t }
    }

    static func opacity(_ layer: CALayer?, _ o: Double) {
        let a = Float(min(max(o, 0), 1))
        if let layer, layer.opacity != a { layer.opacity = a }
    }
}

extension PanelController {
    /// The rise travels the glass height plus 40 pt, so its shadow starts out of sight too.
    static let riseExtra = 40.0

    // MARK: Rise

    /// Sets the from-state and starts the rise: the glass rises on `arrive` (bounce 0, never past
    /// rest) and materialises as it comes: opacity 0 → 1 and scale 0.98 → 1 over 360 ms on
    /// `materialise`, so the backdrop frost builds in rather than switching on (the glass's blur
    /// radius can't be animated, and no filter is ever put on it). The cards come into focus
    /// 40 ms + 12 ms apart. Input works from the first frame.
    /// Under Reduce Motion the glass only fades in over 150 ms and the cards only fade.
    func startRise() {
        let h = targetHeight + Self.riseExtra
        rise.travel = h
        Diagnostics.shared.riseStarted(travel: h)
        if Motion.reduce {
            rise.y.set(0)
            rise.op.set(0)
            rise.op.tween(to: 1, ms: 150) { [weak self] in self?.opened() }
        } else {
            rise.y.set(h)
            rise.op.set(0)
            rise.scale.set(Motion.materialiseScale)
            rise.y.spring(to: 0, duration: Motion.arrive) { [weak self] in self?.opened() }
            rise.op.tween(to: 1, ms: Motion.materialiseMs, ease: Motion.materialise)
            rise.scale.tween(to: 1, ms: Motion.materialiseMs, ease: Motion.materialise)
        }
        entrance()
    }

    /// Cards in view, in reading order, each coming into focus: 20 → 0 pt blur, 1.06 → 1, 16 pt
    /// rise on `focus` over 400 ms, opacity over 260 ms, 40 ms + 12 ms × its place, or all at 40 ms when Settings › Motion › Card
    /// entrance is Together. The selection ring rides its card.
    private func entrance() {
        let stagger = prefs.entrance == .stagger ? 12.0 : 0
        for (i, m) in cardsInView().enumerated() {
            board.born(m, blur: 20, delay: 40 + stagger * Double(i), scale: 1.06, rise: 16, focus: true)
        }
        if model.clips.isEmpty { content.emptyFx.born(blur: 20, delay: 40, scale: 1.06, focus: true) }
    }

    /// The cards the open panel shows, top row first, left to right.
    func cardsInView() -> [CardMotion] {
        let v = viewAt(height: glass.h.dest).offsetBy(dx: board.viewport.minX, dy: board.viewport.minY)
        return board.order.compactMap { c -> CardMotion? in
            guard let m = board.motions[c.id], let r = board.restingRect(c.id),
                  r.insetBy(dx: 1, dy: 1).intersects(v) else { return nil }
            return m
        }.sorted { a, b in
            let ra = board.restingRect(a.id) ?? .zero, rb = board.restingRect(b.id) ?? .zero
            return ra.minY != rb.minY ? ra.minY < rb.minY : ra.minX < rb.minX
        }
    }

    func opened() {
        guard phase == .opening else { return }
        phase = .open
        Diagnostics.shared.riseEnded()
    }

    // MARK: Exit

    /// Accelerates away, faster than it came: the glass drops by its height + 40 pt on `leave`
    /// over 180 ms, carrying the speed it had; it fades out from 60 to 180 ms, and the cards blur
    /// 0 → 10 pt over 120 ms. Ordered out when it ends. Reduce Motion: a 120 ms fade.
    func startExit() {
        let h = glass.h.v + Self.riseExtra
        rise.travel = h
        Diagnostics.shared.begin(.close)
        if Motion.reduce {
            rise.op.tween(to: 0, ms: max(1, 120 * rise.op.v)) { [weak self] in self?.finishClose() }
            return
        }
        rise.y.tween(to: h, ms: 180, ease: Motion.leave, carry: true) { [weak self] in self?.finishClose() }
        if rise.op.v >= 0.999 {
            rise.op.tween(to: 0, ms: 120, delay: 60)
        } else {
            rise.op.tween(to: 0, ms: max(1, 120 * rise.op.v))
        }
        // A card already leaving (removed, op heading to 0) keeps its own exit.
        rise.blurred = cardsInView().filter { $0.op.dest > 0.5 }
        for m in rise.blurred { m.blur.tween(to: 10, ms: 120, ease: Motion.easeIn) }
        if !content.emptyHost.isHidden { content.emptyFx.blur.tween(to: 10, ms: 120, ease: Motion.easeIn) }
    }

    /// The shortcut pressed while the panel leaves: it re-aims from where it is, with the speed it
    /// has. Never restarts, never queues; the pending order-out is dropped. Reduce Motion: the
    /// fade reverses.
    func reaimOpen() {
        phase = .opening
        Diagnostics.shared.begin(.open)
        if Motion.reduce {
            rise.op.tween(to: 1, ms: max(1, 150 * (1 - rise.op.v))) { [weak self] in self?.opened() }
            return
        }
        Diagnostics.shared.riseStarted(travel: rise.y.v, reaim: true)
        rise.y.spring(to: 0, duration: Motion.arrive) { [weak self] in self?.opened() }
        rise.op.tween(to: 1, ms: max(1, Motion.materialiseMs * (1 - rise.op.v)), ease: Motion.materialise)
        if rise.scale.v < 1 { rise.scale.tween(to: 1, ms: max(1, Motion.materialiseMs * (1 - rise.op.v)), ease: Motion.materialise) }
        // Back into focus on the same curve, for as long as the blur left needs (the exit blurs to 10).
        func refocus(_ blur: Anim, _ op: Anim) {
            if blur.v > 0 { blur.tween(to: 0, ms: max(1, Motion.focusMs * min(1, blur.v / 10)), ease: Motion.focus) }
            if op.v < 1 { op.tween(to: 1, ms: 100, ease: Motion.fadeIn) }
        }
        for m in cardsInView() where m.op.dest > 0.5 { refocus(m.blur, m.op) }
        if !content.emptyHost.isHidden { refocus(content.emptyFx.blur, content.emptyFx.op) }
    }

    /// Ends a running exit at once (a key arrived, or the paste needs the keyboard back now).
    func cutExit() {
        guard phase == .closing else { return }
        rise.y.stop()
        rise.op.stop()
        finishClose()
    }

    /// Draws the rise: whole device pixels, no filter on the glass ever.
    func renderRise(sample: Bool = true) {
        let scale = screen?.backingScaleFactor ?? 2
        let dy = pixelSnap(rise.y.v, scale: scale)
        surface.present(drop: dy, opacity: rise.op.v, scale: rise.scale.v)
        if sample { Diagnostics.shared.riseFrame(rise.y.v, rising: phase == .opening) }
    }
}

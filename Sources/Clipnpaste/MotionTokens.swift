import AppKit
import QuartzCore
import ClipnpasteCore

/// The plan's motion tokens (section 5), each tied to Irfan's rulings: springs with bounce 0 that
/// never pass their resting value, exits that accelerate away, house easing on fades, a 1.08 pop.
/// Every moving thing in the panel uses these and nothing else.
enum Motion {
    /// Fast attack, no overshoot: 70% of the travel by 133 ms, parked by 340 ms.
    static let arrive = 0.34
    static let settle = 0.30
    static let quick = 0.22
    /// Smoothing for live values (the drag tilt), re-aimed every frame.
    static let track = 0.12

    /// Exits: leave at about 3× their average speed.
    static let leave = CubicBezier(0.45, 0, 0.8, 0.4)
    /// House easing: 33.3 leaving, 100 arriving.
    static let fadeIn = CubicBezier(0.333, 0, 0, 1)
    static let popUp = CubicBezier(0.2, 0, 0, 1)
    static let popDown = CubicBezier(0.333, 0, 0, 1)
    static let easeIn = CubicBezier(0.42, 0, 1, 1)
    static let linear = CubicBezier.linear

    /// 1 → 1.08 → 1: 60 ms attack, 140 ms return.
    static let popPeak = 1.08
    /// The press dip on small controls, held while pressed.
    static let dipControl = 0.92
    static let dipPill = 0.94
    static let dipMs = 70.0

    /// Under Reduce Motion: no travel, no scale, no tilt; fades and cuts instead.
    @MainActor static var reduce = false
}

@MainActor
protocol MotionTarget: AnyObject {
    func render()
}

/// One display link for everything that moves. Steps the active values, then lets each owner
/// draw once per frame. Runs only while something moves.
@MainActor
final class MotionClock: NSObject {
    static let shared = MotionClock()

    private var link: CADisplayLink?
    private var active: [ObjectIdentifier: Anim] = [:]
    private var dirty: [ObjectIdentifier: MotionTarget] = [:]
    private var hooks: [Int: (Double) -> Void] = [:]
    private var nextHook = 0
    /// When the frame being drawn reaches the screen (the display link's target time).
    private(set) var lastTarget: CFTimeInterval = 0
    /// `--slow-motion N` divides time by N (debug screenshots only); 1 otherwise.
    var timeScale = 1.0
    private var inFrame = false
    private weak var screen: NSScreen?

    /// Nothing is moving and nothing is waiting to draw.
    var isIdle: Bool { active.isEmpty && hooks.isEmpty && dirty.isEmpty }

    /// Follows the screen the panel is on, so the frame rate is that display's.
    func use(screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main, screen != self.screen || link == nil else { return }
        self.screen = screen
        link?.invalidate()
        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        l.isPaused = isIdle
        link = l
    }

    func activate(_ a: Anim) {
        active[ObjectIdentifier(a)] = a
        kick()
    }

    func deactivate(_ a: Anim) { active[ObjectIdentifier(a)] = nil }

    func markDirty(_ t: MotionTarget?) {
        guard let t else { return }
        dirty[ObjectIdentifier(t)] = t
        kick()
    }

    /// A function called every frame with the frame's duration, until removed.
    @discardableResult
    func addHook(_ f: @escaping (Double) -> Void) -> Int {
        nextHook += 1
        hooks[nextHook] = f
        kick()
        return nextHook
    }

    func removeHook(_ id: Int?) {
        guard let id else { return }
        hooks[id] = nil
    }

    /// Draws everything waiting now, before something becomes visible.
    func flush() {
        let d = dirty
        dirty.removeAll()
        for t in d.values { t.render() }
    }

    private func kick() {
        if link == nil { use(screen: nil) }
        guard let link, link.isPaused, !inFrame else { return }
        lastTarget = CACurrentMediaTime()
        link.isPaused = false
    }

    @objc private func tick(_ l: CADisplayLink) {
        inFrame = true
        let now = l.targetTimestamp
        let dt = min(max(now - lastTarget, 0), 0.1) / timeScale
        lastTarget = now
        for h in Array(hooks.values) { h(dt) }
        for a in Array(active.values) where !a.step(dt) {
            if !a.busy { active[ObjectIdentifier(a)] = nil }
        }
        flush()
        inFrame = false
        if isIdle { l.isPaused = true }
    }
}

/// A value that springs, tweens or is set, and tells its owner to redraw. A port of the
/// prototype's motion core: the spring is Apple's duration + bounce 0 and keeps its speed when
/// re-aimed; a tween is a CSS cubic Bézier.
@MainActor
final class Anim {
    private enum Kind {
        case spring(to: Double, omega: Double, side: Double)
        case tween(from: Double, to: Double, duration: Double, ease: CubicBezier, t: Double, carry: Double)
    }

    private(set) var value: Double
    private(set) var velocity: Double = 0
    weak var owner: MotionTarget?
    let eps: Double
    private var kind: Kind?
    private var delay: Double = 0
    private var done: (() -> Void)?
    /// Called with every new value, for the motion logs.
    var probe: ((Double) -> Void)?

    init(_ value: Double, owner: MotionTarget?, eps: Double = 0.01) {
        self.value = value
        self.owner = owner
        self.eps = eps
    }

    var v: Double { value }
    var busy: Bool { kind != nil }
    /// Where it is heading, or where it is.
    var dest: Double {
        switch kind {
        case .spring(let to, _, _): to
        case .tween(_, let to, _, _, _, _): to
        case nil: value
        }
    }

    func set(_ x: Double) {
        value = x
        velocity = 0
        kind = nil
        done = nil
        MotionClock.shared.deactivate(self)
        changed()
    }

    func stop() {
        kind = nil
        velocity = 0
        done = nil
        MotionClock.shared.deactivate(self)
    }

    /// Springs to `to` over the perceptual `duration`, keeping its speed unless `velocity` is given.
    func spring(to: Double, duration: Double, velocity v0: Double? = nil, delay ms: Double = 0,
                done: (() -> Void)? = nil) {
        if let v0 { velocity = v0 }
        delay = ms / 1000
        if delay > 0 { velocity = 0 }
        let side = sign(value - to) != 0 ? sign(value - to) : sign(velocity)
        kind = .spring(to: to, omega: Spring.omega(duration: duration), side: side)
        self.done = done
        MotionClock.shared.activate(self)
        changed()
    }

    /// Re-aims a running spring at a new target without losing its speed, or starts one.
    func aim(_ to: Double, duration: Double = Motion.arrive) {
        if case .spring(_, let w, let side) = kind {
            let s = sign(value - to)
            kind = .spring(to: to, omega: w, side: s != 0 ? s : side)
            MotionClock.shared.activate(self)
        } else if abs(value - to) > eps {
            spring(to: to, duration: duration)
        }
    }

    /// A keyed move: `ms` long on `ease`. `carry` blends the current speed in so a re-aimed exit
    /// never jumps.
    func tween(to: Double, ms: Double, ease: CubicBezier = Motion.linear, delay d: Double = 0,
               carry: Bool = false, done: (() -> Void)? = nil) {
        kind = .tween(from: value, to: to, duration: max(ms / 1000, 0.001), ease: ease, t: 0, carry: carry ? velocity : 0)
        delay = d / 1000
        self.done = done
        MotionClock.shared.activate(self)
        changed()
    }

    /// Two or three keys in a row (a pop is rest → peak → rest).
    func keys(_ list: [(to: Double, ms: Double, ease: CubicBezier)], done: (() -> Void)? = nil) {
        guard let first = list.first else { done?(); return }
        let rest = Array(list.dropFirst())
        tween(to: first.to, ms: first.ms, ease: first.ease) { [weak self] in
            self?.keys(rest, done: done)
        }
    }

    /// The 1.08 pop: 60 ms up on popUp, 140 ms back on popDown.
    func pop(_ peak: Double = Motion.popPeak) {
        keys([(peak, 60, Motion.popUp), (1, 140, Motion.popDown)])
    }

    /// Moves the value and its target together, so a running motion carries on from a new origin.
    func shift(by d: Double) {
        value += d
        switch kind {
        case .spring(let to, let w, let side): kind = .spring(to: to + d, omega: w, side: side)
        case .tween(let from, let to, let dur, let ease, let t, let c): kind = .tween(from: from + d, to: to + d, duration: dur, ease: ease, t: t, carry: c)
        case nil: break
        }
        changed()
    }

    /// Returns false when this value has stopped moving.
    func step(_ dt0: Double) -> Bool {
        guard let k = kind else { return false }
        var dt = dt0
        if delay > 0 {
            delay -= dt
            if delay > 0 { return true }
            dt = -delay
            delay = 0
            switch k {
            case .tween(_, let to, let dur, let ease, let t, let c): kind = .tween(from: value, to: to, duration: dur, ease: ease, t: t, carry: c)
            case .spring(let to, let w, _):
                let s = sign(value - to)
                kind = .spring(to: to, omega: w, side: s != 0 ? s : sign(velocity))
            }
        }
        switch kind! {
        case .spring(let to, let w, let side):
            let (x, v) = Spring.step(offset: value - to, velocity: velocity, omega: w, dt: dt, side: side)
            value = to + x
            velocity = v
            if abs(x) < eps, abs(v) < eps * 12 { return finish(to) }
        case .tween(let from, let to, let dur, let ease, let t0, let carry):
            let t = t0 + dt
            let p = min(1, t / dur)
            var nv = from + (to - from) * ease(p)
            if carry != 0 { nv += carry * t * exp(-t / 0.05) * (1 - p) * (1 - p) }
            if dt > 0 { velocity = (nv - value) / dt }
            value = nv
            kind = .tween(from: from, to: to, duration: dur, ease: ease, t: t, carry: carry)
            if p >= 1 { return finish(to) }
        }
        changed()
        return true
    }

    private func finish(_ to: Double) -> Bool {
        value = to
        velocity = 0
        kind = nil
        let d = done
        done = nil
        changed()
        d?()
        return kind != nil
    }

    private func changed() {
        probe?(value)
        MotionClock.shared.markDirty(owner)
    }

    private func sign(_ x: Double) -> Double { x > 0 ? 1 : (x < 0 ? -1 : 0) }
}

extension Anim {
    /// Springs, or under Reduce Motion jumps.
    func move(to x: Double, duration: Double, velocity: Double? = nil, done: (() -> Void)? = nil) {
        if Motion.reduce {
            set(x)
            done?()
        } else {
            spring(to: x, duration: duration, velocity: velocity, done: done)
        }
    }
}

/// Snaps a length to the display's pixel grid.
@MainActor
func pixelSnap(_ x: Double, scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2) -> CGFloat {
    (CGFloat(x) * scale).rounded() / scale
}

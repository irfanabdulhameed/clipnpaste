import Foundation

/// Apple's spring with bounce 0: critically damped, ω = 2π / duration. It keeps its speed when
/// re-aimed and, as Irfan's rule asks, never passes its resting value.
public enum Spring {
    public static func omega(duration: Double) -> Double { 2 * Double.pi / duration }

    /// Advances a spring by `dt` seconds. `offset` is the distance from the target.
    /// `side` is the sign the offset started on; the spring stops at the target instead of crossing it.
    public static func step(offset x0: Double, velocity v0: Double, omega w: Double, dt: Double,
                            side: Double = 0) -> (offset: Double, velocity: Double) {
        let b = v0 + w * x0, e = exp(-w * dt)
        var x = (x0 + b * dt) * e
        var v = (v0 - w * b * dt) * e
        if side != 0, x != 0, (x > 0 ? 1.0 : -1.0) == -side {
            x = 0
            v = 0
        }
        return (x, v)
    }

    /// The share of the travel done after `t` seconds from rest: 1 − (1 + ωt)e^(−ωt).
    public static func progress(duration: Double, at t: Double) -> Double {
        let wt = omega(duration: duration) * t
        return 1 - (1 + wt) * exp(-wt)
    }
}

/// A CSS-style cubic Bézier timing curve, `cubic-bezier(x1, y1, x2, y2)`.
public struct CubicBezier: Sendable, Equatable {
    public let x1: Double, y1: Double, x2: Double, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    public static let linear = CubicBezier(0, 0, 1, 1)

    public func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
        let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
        func sx(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
        func sy(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
        func dsx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }
        var t = x
        for _ in 0..<8 {
            let d = sx(t) - x
            if abs(d) < 1e-7 { return sy(t) }
            let dd = dsx(t)
            if abs(dd) < 1e-7 { break }
            t -= d / dd
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<50 {
            let v = sx(t)
            if abs(v - x) < 1e-7 { break }
            if x > v { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sy(t)
    }
}

import AppKit
import Carbon
import QuartzCore
import ClipnpasteCore
import os

/// Launch flags for measuring and checking the panel's motion.
enum DiagnosticFlags {
    private static let args = ProcessInfo.processInfo.arguments
    /// `--measure` (always on in a debug build): logs open latency, frame gaps and the rise.
    static let measure: Bool = {
        #if DEBUG
        return true
        #else
        return args.contains("--measure")
        #endif
    }()
    /// `--slow-motion N`: every motion runs N times slower, for screenshots mid-rise.
    static let slowMotion: Double? = value(after: "--slow-motion").flatMap(Double.init)
    /// `--pasteboard-banner`: shows the pasteboard banner as if access were set to ask.
    static let pasteboardBanner = args.contains("--pasteboard-banner")
    /// `--measure-cycles N`: open and close cycles in the measure scene (20).
    static let cycles = value(after: "--measure-cycles").flatMap { Int($0) } ?? 20

    private static func value(after flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
}

/// Speed instrumentation (plan section 7), only with `--measure` or in a debug build:
/// - open latency: the shortcut (the Carbon hot-key event's own time when the shortcut opened it)
///   to the first display-link frame after the panel is ordered front;
/// - frame pacing: every gap between display-link frames during an open, a close, a history
///   change and scrolling; a gap over 1.5× the refresh interval is a long frame;
/// - the rise: the glass's position at every frame, and its shape.
/// Lines go to stderr and to the unified log (subsystem com.irfanabdulhameed.clipnpaste,
/// category measure), so `log stream` shows them for the installed app too.
@MainActor
final class Diagnostics: NSObject {
    static let shared = Diagnostics()

    enum Kind: String, CaseIterable { case open, close, history, scroll }

    struct Session {
        let kind: Kind
        let start: CFTimeInterval
        var frames = 0
        var long = 0
        var maxGap = 0.0
        var last: CFTimeInterval?
        var interval = 1.0 / 60
        var ending = false
    }

    struct Pacing {
        let frames: Int
        let long: Int
        let maxGapMs: Double
        let intervalMs: Double
    }

    struct Shape {
        let at133: Double, at167: Double, at340: Double
        let overshoot: Double
        /// When it came within 0.5 pt of rest.
        let parkedMs: Double?
    }

    private let logger = Logger(subsystem: "com.irfanabdulhameed.clipnpaste", category: "measure")
    private var link: CADisplayLink?
    private weak var screen: NSScreen?

    private var triggerAt: CFTimeInterval = 0
    private var fromHotKey = false
    private var frontAt: CFTimeInterval = 0
    private var awaitingFirstFrame = false
    private(set) var latencies: [Double] = []

    private var session: Session?
    private var lastScrollAt: CFTimeInterval = 0
    private(set) var pacing: [Kind: [Pacing]] = [:]

    /// When the last rise started (recorded even when not measuring, for the self-test).
    private(set) var riseStart: CFTimeInterval = 0
    private var riseTravel = 0.0
    private(set) var riseTrace: [(t: Double, y: Double)] = []
    private(set) var shapes: [Shape] = []
    /// Log every frame of the rise (on by default; the measure scene logs only its first).
    var logRiseFrames = true

    var enabled: Bool { DiagnosticFlags.measure }

    /// At launch: slow motion for screenshots.
    func configure() {
        if let s = DiagnosticFlags.slowMotion, s > 0 { MotionClock.shared.timeScale = s }
    }

    func note(_ s: String) {
        FileHandle.standardError.write(Data("[Clipnpaste] measure: \(s)\n".utf8))
        logger.notice("\(s, privacy: .public)")
    }

    // MARK: Open latency

    /// The shortcut (or a call to open): its time, from the hot-key event when there is one.
    func triggered() {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        triggerAt = now
        fromHotKey = false
        if let t = Self.hotKeyEventTime(), t <= now, now - t < 1 {
            triggerAt = t
            fromHotKey = true
        }
        begin(.open)
    }

    /// The Carbon hot-key event being handled now, if the shortcut is what called us.
    private static func hotKeyEventTime() -> CFTimeInterval? {
        guard let event = GetCurrentEvent(), GetEventClass(event) == OSType(kEventClassKeyboard),
              GetEventKind(event) == UInt32(kEventHotKeyPressed) else { return nil }
        let t = GetEventTime(event)
        return t > 0 ? t : nil
    }

    func orderedFront(on screen: NSScreen?) {
        guard enabled else { return }
        frontAt = CACurrentMediaTime()
        awaitingFirstFrame = true
        run(on: screen)
    }

    // MARK: Frame pacing

    func begin(_ kind: Kind) {
        guard enabled else { return }
        if let s = session { finish(s) }
        session = Session(kind: kind, start: CACurrentMediaTime())
        run(on: screen)
    }

    /// The close has ordered the panel out: its session ends once nothing moves.
    func closed() {
        guard enabled, session?.kind == .close else { return }
        session?.ending = true
    }

    /// A scroll wheel event (or a step of a measured steady scroll).
    func scrolled() {
        guard enabled else { return }
        lastScrollAt = CACurrentMediaTime()
        if session == nil { begin(.scroll) }
    }

    private func run(on s: NSScreen?) {
        let target = s ?? screen ?? NSScreen.main
        if link == nil || target != screen {
            link?.invalidate()
            guard let target else { return }
            screen = target
            let l = target.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.targetTimestamp
        let interval = max(l.targetTimestamp - l.timestamp, 1.0 / 240)
        if awaitingFirstFrame {
            awaitingFirstFrame = false
            // The window is composited at the first refresh after its commit: the frame that has
            // just gone out (`timestamp`) if the commit made it, else the next (`targetTimestamp`).
            // The later one is logged as the latency; the earlier is the best case.
            let ms = (now - triggerAt) * 1000
            let best = max(l.timestamp - triggerAt, frontAt - triggerAt) * 1000
            latencies.append(ms)
            note(String(format: "open latency %.1f ms, best case %.1f ms (%@ to the first frame on screen; main-thread work %.1f ms) — target ≤ 50 ms",
                        ms, best, fromHotKey ? "hot-key event" : "open call", (frontAt - triggerAt) * 1000))
        }
        if var s = session {
            if let last = s.last {
                let gap = now - last
                s.maxGap = max(s.maxGap, gap)
                if gap > 1.5 * interval { s.long += 1 }
            }
            s.last = now
            s.frames += 1
            s.interval = interval
            session = s
            let age = CACurrentMediaTime() - s.start
            let idle = MotionClock.shared.isIdle
            let done: Bool
            switch s.kind {
            case .open, .history: done = idle && age > 0.05
            case .close: done = (s.ending && idle) || age > 3
            case .scroll: done = idle && CACurrentMediaTime() - lastScrollAt > 0.25
            }
            if done || age > 5 { finish(s) }
        }
        if session == nil && !awaitingFirstFrame { l.isPaused = true }
    }

    private func finish(_ s: Session) {
        session = nil
        let p = Pacing(frames: s.frames, long: s.long, maxGapMs: s.maxGap * 1000, intervalMs: s.interval * 1000)
        pacing[s.kind, default: []].append(p)
        note(String(format: "%@: %d frames, %d longer than 1.5× the %.1f ms refresh, longest gap %.1f ms",
                    s.kind.rawValue, p.frames, p.long, p.intervalMs, p.maxGapMs))
    }

    // MARK: The rise

    private var reaim = false

    func riseStarted(travel: Double, reaim: Bool = false) {
        riseStart = CACurrentMediaTime()
        self.reaim = reaim
        guard enabled else { return }
        riseTravel = travel
        riseTrace = []
    }

    /// Every frame of the rise: the glass's distance below rest.
    func riseFrame(_ y: Double, rising: Bool) {
        guard enabled, rising, riseTravel > 0 else { return }
        let t = max(0, MotionClock.shared.lastTarget - riseStart)
        if let last = riseTrace.last, abs(last.t - t) < 0.0005 { riseTrace.removeLast() }
        riseTrace.append((t, y))
        if logRiseFrames {
            note(String(format: "rise +%5.1f ms: glass %6.1f pt below rest (%5.1f%% of %.0f pt)",
                        t * 1000, y, (1 - y / riseTravel) * 100, riseTravel))
        }
    }

    func riseEnded() {
        guard enabled, riseTravel > 0, riseTrace.count > 1 else { return }
        let s = Self.shape(riseTrace, travel: riseTravel)
        if !reaim { shapes.append(s) }
        note(String(format: "%@ shape: %.1f%% at 133 ms (≥ 70), %.1f%% at 167 ms (81), %.1f%% at 340 ms (98.6), %.2f pt past rest (0), within 0.5 pt at %@",
                    reaim ? "re-aimed rise (from mid-exit, so not the rest-to-rest curve)" : "rise", s.at133 * 100, s.at167 * 100, s.at340 * 100, s.overshoot,
                    s.parkedMs.map { String(format: "%.0f ms", $0) } ?? "—"))
        riseTravel = 0
    }

    /// The share of the travel done at `t` seconds, read off the frames (linear between them).
    static func fraction(_ trace: [(t: Double, y: Double)], travel: Double, at t: Double) -> Double {
        guard let first = trace.first, travel > 0 else { return 0 }
        var prev = first
        for p in trace {
            if p.t >= t {
                let k = p.t > prev.t ? (t - prev.t) / (p.t - prev.t) : 1
                let y = prev.y + (p.y - prev.y) * min(max(k, 0), 1)
                return 1 - y / travel
            }
            prev = p
        }
        return 1 - prev.y / travel
    }

    static func shape(_ trace: [(t: Double, y: Double)], travel: Double) -> Shape {
        let minY = trace.map(\.y).min() ?? 0
        let parked = trace.first { $0.y <= 0.5 }?.t
        return Shape(at133: fraction(trace, travel: travel, at: 0.133), at167: fraction(trace, travel: travel, at: 0.167),
                     at340: fraction(trace, travel: travel, at: 0.340), overshoot: max(0, -minY),
                     parkedMs: parked.map { $0 * 1000 })
    }

    // MARK: Summary

    /// Forgets what was measured so far (the measure scene's setup).
    func reset() {
        latencies = []
        pacing = [:]
        shapes = []
    }

    func summary() {
        let l = latencies.sorted()
        if !l.isEmpty {
            note(String(format: "SUMMARY open latency over %d opens: median %.1f ms, worst %.1f ms (target ≤ 50 ms)",
                        l.count, l[l.count / 2], l.last ?? 0))
        }
        for k in Kind.allCases {
            guard let list = pacing[k], !list.isEmpty else { continue }
            let long = list.map(\.long).reduce(0, +)
            let frames = list.map(\.frames).reduce(0, +)
            let worst = list.map(\.maxGapMs).max() ?? 0
            let target = k == .scroll ? "0 in steady scrolling" : "≤ 1 per open or close"
            note(String(format: "SUMMARY %@: %d runs, %d frames, %d long (%.2f per run), longest gap %.1f ms, refresh %.1f ms (target %@)",
                        k.rawValue, list.count, frames, long, Double(long) / Double(list.count), worst, list.last?.intervalMs ?? 0, target))
        }
        if !shapes.isEmpty {
            let n = Double(shapes.count)
            let a133 = shapes.map(\.at133).reduce(0, +) / n, a340 = shapes.map(\.at340).reduce(0, +) / n
            let worst133 = shapes.map(\.at133).min() ?? 0
            let over = shapes.map(\.overshoot).max() ?? 0
            note(String(format: "SUMMARY rise over %d opens: %.1f%% at 133 ms (lowest %.1f%%, target ≥ 70), %.1f%% at 340 ms (target 98.6), worst overshoot %.2f pt (target 0)",
                        shapes.count, a133 * 100, worst133 * 100, a340 * 100, over))
        }
    }
}

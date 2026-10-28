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

// MARK: - The measure scene and the self-test steps

extension PanelController {
    /// `--scene measure --measure`: 20 open/close cycles opened the way the shortcut does, an
    /// interrupted open, a steady scroll along the row, history in, a steady scroll down it and
    /// out, then a summary against section 7's targets. Quits when done.
    func runMeasureScene() async {
        let d = Diagnostics.shared
        guard d.enabled else {
            debugLog("the measure scene needs --measure")
            return
        }
        func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func until(_ ok: () -> Bool) async {
            let start = CACurrentMediaTime()
            while !ok() && CACurrentMediaTime() - start < 4 { await wait(8) }
        }
        func idle() async {
            await until { MotionClock.shared.isIdle }
            await wait(120)
        }
        // A long row and a long history to scroll.
        let now = Date()
        for i in 0..<160 {
            let text = "Measure clip \(i + 1): a line of notes long enough to wrap onto a second line in the card."
            store.insertOrBump(Clip(kind: .text, plainText: text, sourceBundleID: "com.apple.Notes", sourceAppName: "Notes",
                                    createdAt: now.addingTimeInterval(-3_600 * Double(i)), contentHash: DemoClips.hash(text)))
        }
        await idle()
        await wait(300)
        d.reset()
        for i in 0..<DiagnosticFlags.cycles {
            d.logRiseFrames = i == 0
            toggle()
            await until { phase == .closed }
            await wait(150)
            toggle()
            // The first open, frame by frame: the glass materialising and the cards coming into focus.
            var hook: Int?
            if i == 0 {
                let cards = cardsInView()
                hook = MotionClock.shared.addHook { [unowned self] _ in
                    let t = (MotionClock.shared.lastTarget - d.riseStart) * 1000
                    d.note(String(format: "open +%5.1f ms: glass op %.3f scale %.4f y %6.1f | card 1 blur %5.2f op %.3f | card %d blur %5.2f",
                                  t, self.rise.op.v, self.rise.scale.v, self.rise.y.v,
                                  cards.first?.blur.v ?? 0, cards.first?.op.v ?? 0, cards.count, cards.last?.blur.v ?? 0))
                }
            }
            await until { phase == .open }
            if let hook {
                // The hook keeps the clock running, so wait for the motion itself, then remove it.
                let cards = cardsInView()
                await until { !rise.busy && !cards.contains(where: \.busy) }
                MotionClock.shared.removeHook(hook)
                await idle()
                let f = filteredLayers()
                d.note("open at rest: \(f.count) filtered layers\(f.isEmpty ? "" : " (" + f.joined(separator: ", ") + ")"), glass op \(rise.op.v), scale \(rise.scale.v)")
            } else {
                await idle()
            }
        }
        d.logRiseFrames = false
        // Interrupted: close 90 ms into the rise, re-open 80 ms into the exit.
        toggle(); await until { phase == .closed }; await wait(150)
        toggle(); await wait(90)
        toggle(); await wait(80)
        toggle(); await until { phase == .open }; await idle()
        d.note(String(format: "interrupted open re-aimed and parked: y %.2f pt, phase %@", rise.y.v, "\(phase)"))

        await steadyScroll(vertical: false, speed: 1500, seconds: 1.6)
        board.scroll(to: .zero, instant: true)
        await idle()
        toggleHistory()
        await idle()
        await steadyScroll(vertical: true, speed: 1500, seconds: 1.6)
        board.scroll(to: .zero, instant: true)
        await idle()
        toggleHistory()
        await idle()
        d.summary()
        NSApp.terminate(nil)
    }

    /// Scrolls at a constant speed, one step per frame, as a trackpad flick in its steady part.
    private func steadyScroll(vertical: Bool, speed: Double, seconds: Double) async {
        let d = Diagnostics.shared
        var p = board.viewport.origin
        let start = CACurrentMediaTime()
        d.begin(.scroll)
        let hook = MotionClock.shared.addHook { [weak self] dt in
            guard let self else { return }
            if vertical { p.y += speed * dt } else { p.x += speed * dt }
            let m = self.board.maxScroll
            p = CGPoint(x: min(p.x, m.x), y: min(p.y, m.y))
            self.board.scrollNow(to: p)
            d.scrolled()
        }
        while CACurrentMediaTime() - start < seconds { try? await Task.sleep(for: .milliseconds(50)) }
        MotionClock.shared.removeHook(hook)
        while !MotionClock.shared.isIdle { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// Layers in the panel that carry a filter (hidden ones and their children skipped).
    func filteredLayers() -> [String] {
        var out: [String] = []
        func walk(_ l: CALayer) {
            guard !l.isHidden else { return }
            if let f = l.filters, !f.isEmpty { out.append(l.delegate.map { "\(type(of: $0))" } ?? "\(type(of: l))") }
            for s in l.sublayers ?? [] { walk(s) }
        }
        if let l = content.layer { walk(l) }
        if surface.layer?.filters?.isEmpty == false { out.append("glass") }
        return out
    }

    /// The panel-level motion steps of `--self-test`: rise, interruption, exit after a paste,
    /// history in and out, no filters at rest, the toast, and the rise on an opaque surface.
    func runPanelMotionChecks(_ check: @escaping (String, Bool, String) -> Void) async {
        func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func until(_ ok: () -> Bool) async {
            let start = CACurrentMediaTime()
            while !ok() && CACurrentMediaTime() - start < 3 { await wait(8) }
        }
        func settle() async {
            await wait(40)
            await until { MotionClock.shared.isIdle }
            await wait(30)
        }
        func key(_ code: Int) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: panel.windowNumber, context: nil, characters: "",
                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) {
                panel.sendEvent(e)
            }
        }
        func f(_ x: Double) -> String { String(format: "%.2f", x) }
        let rm = Motion.reduce

        await until { phase == .closed }
        check("Esc: the exit ends with the panel ordered out", phase == .closed && !panel.isVisible,
              "phase \(phase), visible \(panel.isVisible)")
        check("closed: the glass is back at rest for the next open",
              rise.y.v == 0 && rise.op.v == 1 && cardsInView().allSatisfy { $0.blur.v == 0 }, "y \(rise.y.v), op \(rise.op.v)")

        // The rise, read at every frame it draws.
        func measureRise(_ label: String) async {
            var trace: [(t: Double, y: Double)] = []
            var minY = Double.infinity
            var glassFiltered = false
            // Time from the spring's start, as the frames reach the screen.
            rise.y.probe = { [unowned self] v in
                trace.append((max(0, MotionClock.shared.lastTarget - Diagnostics.shared.riseStart), v))
                minY = min(minY, v)
                if self.surface.layer?.filters?.isEmpty == false { glassFiltered = true }
            }
            toggle()
            let h = rise.travel
            let cards = cardsInView()
            trace = [(0, rise.y.v)]
            check("\(label): on screen at once, drawn in its from-state",
                  panel.isVisible && phase == .opening && rise.op.v == 0 && (rm ? rise.y.v == 0 : abs(rise.y.v - h) < 0.01),
                  "visible \(panel.isVisible), y \(rise.y.v) of \(h), op \(rise.op.v)")
            if rm {
                check("\(label), Reduce Motion: the cards only fade (no blur, scale or move)",
                      cards.allSatisfy { $0.blur.v == 0 && $0.es.v == 1 && $0.dy.v == 0 && $0.op.v == 0 }, "")
            } else {
                check("\(label): every card in view is born blurred (20 pt, 1.06, 16 pt low, transparent)",
                      !cards.isEmpty && cards.allSatisfy { $0.blur.v == 20 && $0.es.v == 1.06 && $0.dy.v == 16 && $0.op.v == 0 },
                      "\(cards.count) cards")
                check("\(label): the glass starts at \(Motion.materialiseScale) scale", rise.scale.v == Motion.materialiseScale, "scale \(rise.scale.v)")
                await wait(90)
                let blurs = cards.map(\.blur.v)
                // At ~90 ms the frost is still building and the first card is still well out of focus
                // (the old 120 ms fade had the glass at full opacity and a spring had the blur near 8).
                check("\(label): at 90 ms the glass is still materialising (opacity \(f(rise.op.v)) < 0.8)",
                      rise.op.v > 0.05 && rise.op.v < 0.8, "")
                check("\(label): at 90 ms the first card is still soft (blur \(f(blurs.first ?? 0)) > 12 px)",
                      (blurs.first ?? 20) > 12, "")
                check("\(label): cards enter 12 ms apart (blur rises with the card's place)",
                      blurs.count < 2 || (zip(blurs, blurs.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } && blurs[0] < blurs[blurs.count - 1]),
                      blurs.map(f).joined(separator: " "))
            }
            await settle()
            rise.y.probe = nil
            check("\(label): the glass and cards at rest: opacity 1, scale 1, sharp",
                  rise.scale.v == 1 && cards.allSatisfy { $0.blur.v == 0 && $0.op.v == 1 && $0.es.v == 1 }, "scale \(rise.scale.v)")
            check("\(label): parked at rest and open", phase == .open && rise.y.v == 0 && rise.op.v == 1,
                  "phase \(phase), y \(rise.y.v), op \(rise.op.v)")
            check("\(label): 0 pt past the resting position", minY >= 0, "lowest \(f(minY)) pt")
            if rm {
                check("\(label), Reduce Motion: no travel at all", trace.allSatisfy { $0.y == 0 }, "")
            } else {
                let s = Diagnostics.shape(trace, travel: h)
                check("\(label): \(f(s.at133 * 100))% of the travel by 133 ms (≥ 70%)", s.at133 >= 0.695, "\(trace.count) frames")
                check("\(label): parked by 340 ms (\(f(s.at340 * 100))% ≥ 98%)", s.at340 >= 0.98, "")
            }
            check("\(label): the glass is never filtered", !glassFiltered && surface.layer?.filters == nil, "")
        }

        await measureRise("rise")
        let filtered = filteredLayers()
        check("at rest no layer in the panel has a filter", filtered.isEmpty, filtered.joined(separator: ", "))
        check("at rest the glass has no transform and full opacity",
              surface.layer.map { CATransform3DIsIdentity($0.transform) && $0.opacity == 1 } ?? false, "")

        // Interruption: the shortcut mid-rise turns it around; again mid-exit it turns back.
        toggle()
        await until { phase == .closed }
        await wait(120)
        var maxAfterReaim = -Double.infinity, minAfterReaim = Double.infinity
        var reaimed = false
        var watching = false
        var stayedVisible = true
        rise.y.probe = { [unowned self] v in
            if reaimed { maxAfterReaim = max(maxAfterReaim, v); minAfterReaim = min(minAfterReaim, v) }
            if watching && (!self.panel.isVisible || self.phase == .closed) { stayedVisible = false }
        }
        toggle()
        watching = true
        let h = rise.travel
        await wait(80)
        let y1 = rise.y.v, op1 = rise.op.v
        toggle()
        check("mid-rise: the shortcut turns it around from where it is (no jump)",
              phase == .closing && rise.y.v == y1 && rise.op.v == op1 && panel.isVisible,
              "phase \(phase), y \(f(rise.y.v)) vs \(f(y1))")
        await wait(rm ? 50 : 90)
        let y2 = rise.y.v, op2 = rise.op.v
        if rm {
            check("mid-rise under Reduce Motion: the fade reverses", op2 < op1 && y2 == 0, "op \(f(op1)) → \(f(op2))")
        } else {
            check("mid-exit: it carried its speed, then accelerated away", y2 > y1 && y2 < h, "y \(f(y1)) → \(f(y2)) of \(f(h))")
        }
        reaimed = true
        toggle()
        check("mid-exit: the shortcut re-aims it at once (no restart, not ordered out)",
              phase == .opening && rise.y.v == y2 && rise.op.v == op2 && panel.isVisible, "phase \(phase), y \(f(rise.y.v))")
        await settle()
        rise.y.probe = nil
        check("re-aimed: parked at rest with 0 pt overshoot, never ordered out",
              phase == .open && rise.y.v == 0 && minAfterReaim >= 0 && stayedVisible, "lowest \(f(minAfterReaim)), visible \(stayedVisible)")
        if !rm {
            check("re-aimed: never restarted from below the screen", maxAfterReaim < h - 1, "highest \(f(maxAfterReaim)) of \(f(h))")
        }

        // Exit after a paste: same exit, faster than the rise, accelerating.
        var samples: [(t: Double, y: Double)] = []
        rise.y.probe = { v in samples.append((MotionClock.shared.lastTarget, v)) }
        pasteInterceptor = { _ in }
        interceptedPasteCloses = true
        let tp = CACurrentMediaTime()
        key(kVK_Return)
        check("paste: the panel leaves on its exit (still on screen, clicks pass through)",
              phase == .closing && panel.isVisible, "phase \(phase)")
        await until { phase == .closed }
        let exitMs = (CACurrentMediaTime() - tp) * 1000
        rise.y.probe = nil
        pasteInterceptor = nil
        interceptedPasteCloses = false
        check("paste: ordered out after \(Int(exitMs)) ms (exit 180 ms, the rise takes 340)",
              !panel.isVisible && exitMs < 300, "")
        if rm {
            check("paste under Reduce Motion: a fade, no travel", samples.allSatisfy { $0.y == 0 }, "")
        } else {
            let moving = samples.filter { $0.y > 0 }
            let ok = moving.count >= 4 && zip(moving, moving.dropFirst()).allSatisfy { $0.y <= $1.y }
            var faster = false
            if ok {
                // Speed per frame; the last segment may be a partial frame (the exit ends between
                // frames), so the end speed is the fastest of the last three.
                let v = zip(moving, moving.dropFirst()).map { ($1.y - $0.y) / max($1.t - $0.t, 1e-3) }
                faster = (v.suffix(3).max() ?? 0) > 2 * v[0]
            }
            check("paste: the exit only goes down, and accelerates away", ok && faster,
                  moving.map { String(format: "%.3f:%.1f", $0.t - (moving.first?.t ?? 0), $0.y) }.joined(separator: " "))
        }

        // History in and out. Fresh copies first, so the row's front and history's top (by
        // date) are the same cards, as in daily use.
        let now = Date()
        for i in 0..<30 {
            let text = "Fresh clip \(30 - i) for the history check."
            store.insertOrBump(Clip(kind: .text, plainText: text, sourceBundleID: "com.apple.Notes", sourceAppName: "Notes",
                                    createdAt: now.addingTimeInterval(Double(i) - 30), contentHash: DemoClips.hash(text)))
        }
        toggle()
        await settle()
        func inView() -> Set<UUID> { Set(cardsInView().map(\.id)) }
        /// Every card whose blur goes above 0 while it runs.
        func watch() -> (blurred: () -> Set<UUID>, stop: () -> Void) {
            var seen = Set<UUID>()
            let hook = MotionClock.shared.addHook { [unowned self] _ in
                for (id, m) in self.board.motions where m.blur.v > 0.05 { seen.insert(id) }
            }
            return ({ seen }, { MotionClock.shared.removeHook(hook) })
        }
        let rowIDs = inView()
        var w = watch()
        toggleHistory()
        await settle()
        w.stop()
        let histIDs = inView()
        var carried = rowIDs.intersection(histIDs), born = histIDs.subtracting(rowIDs)
        check("history in: the first row is carried, never blurred", !carried.isEmpty && w.blurred().isDisjoint(with: carried),
              "\(carried.count) carried, \(w.blurred().intersection(carried).count) blurred")
        if rm {
            check("history in, Reduce Motion: the new rows fade, never blur", w.blurred().isEmpty, "")
        } else {
            check("history in: the rows below are born blurred", !born.isEmpty && born.isSubset(of: w.blurred()),
                  "\(born.count) born, \(born.intersection(w.blurred()).count) blurred")
        }
        var left = filteredLayers()
        check("history in: no filter left at rest", left.isEmpty, left.joined(separator: ", "))
        w = watch()
        toggleHistory()
        await settle()
        w.stop()
        let backIDs = inView()
        carried = histIDs.intersection(backIDs)
        let gone = histIDs.subtracting(backIDs)
        check("history out: the first row is carried back, never blurred", !carried.isEmpty && w.blurred().isDisjoint(with: carried), "")
        if rm {
            check("history out, Reduce Motion: instant, no blur", w.blurred().isEmpty, "")
        } else {
            check("history out: the rows below blur out", !gone.isEmpty && gone.isSubset(of: w.blurred()),
                  "\(gone.count) leaving, \(gone.intersection(w.blurred()).count) blurred")
        }
        left = filteredLayers()
        check("history out: no filter left at rest", left.isEmpty, left.joined(separator: ", "))

        // The toast: born blurred, leaves after 1.6 s.
        showToast(on: screen)
        let fx = toast.fx
        check("toast: born \(rm ? "transparent (a fade only)" : "blurred: text 12 pt, capsule 1.06, transparent")",
              toast.isVisible && fx.op.v == 0 && (rm ? fx.blur.v == 0 && fx.scale.v == 1 : fx.blur.v == 12 && fx.scale.v == 1.06),
              "op \(fx.op.v), blur \(fx.blur.v), scale \(fx.scale.v)")
        await settle()
        check("toast: sharp at rest, no filter", fx.blur.v == 0 && fx.scale.v == 1 && fx.op.v == 1 && !toast.textHasFilter, "")
        await wait(Int(Toast.holdMs) + 300)
        check("toast: leaves after 1.6 s and is ordered out", !toast.isVisible, "")

        // Reduce Transparency's opaque surface: the same motion. (A real switch warms the new
        // surface while closed; here one open and close does it.)
        materialOverride = .opaque
        applyDisplayOptions()
        toggle()
        await until { phase == .closed }
        toggle()
        await settle()
        toggle()
        await until { phase == .closed }
        await wait(100)
        await measureRise("opaque surface")
        check("opaque surface: it really was the opaque one", surface.material == .opaque, "\(surface.material)")
        materialOverride = nil
        applyDisplayOptions()
        await settle()
    }
}

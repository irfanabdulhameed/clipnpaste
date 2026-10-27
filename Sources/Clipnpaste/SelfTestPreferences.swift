import AppKit
import Carbon
import ClipnpasteCore

extension PanelController {
    /// Settings apply live: each preference the panel reads is changed while it runs, and the
    /// panel is checked for the change. Every value goes back to its default at the end.
    func preferencesChecks(_ report: @escaping Check) async {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
        let p = prefs
        var clock = ProcessInfo.processInfo.systemUptime
        func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func settle() async {
            let start = CACurrentMediaTime()
            await wait(40)
            while !MotionClock.shared.isIdle && CACurrentMediaTime() - start < 3 { await wait(16) }
            await wait(30)
            clock = max(clock, ProcessInfo.processInfo.systemUptime)
        }
        func key(_ code: Int) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: panel.windowNumber, context: nil, characters: "",
                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) {
                panel.sendEvent(e)
            }
        }
        func mouse(_ type: NSEvent.EventType, _ pt: NSPoint) {
            clock = max(clock + 0.016, ProcessInfo.processInfo.systemUptime)
            if let e = NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [], timestamp: clock,
                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: 1) {
                panel.sendEvent(e)
            }
        }
        func cardPoint(_ i: Int) -> NSPoint {
            let s = screenRect(ofContent: board.restingRect(model.clips[i].id) ?? .zero)
            return panel.convertPoint(fromScreen: NSPoint(x: s.midX, y: s.midY))
        }
        /// Lifts card 0 and carries it `dx` sideways and `dy` up, in ten steps.
        func lift(dx: CGFloat, dy: CGFloat) async -> NSPoint {
            let a = cardPoint(0)
            mouse(.leftMouseDown, a)
            for i in 1...10 {
                mouse(.leftMouseDragged, NSPoint(x: a.x + dx * CGFloat(i) / 10, y: a.y + dy * CGFloat(i) / 10))
                await wait(16)
            }
            await wait(450)
            return a
        }
        func drop(_ a: NSPoint) async {
            key(kVK_Escape)
            await settle()
            mouse(.leftMouseUp, a)
        }
        func f(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "—" }
        let rm = Motion.reduce

        if phase != .closed { close() }
        await settle()
        open()
        await settle()
        check("settings: the panel is open for the live checks", isOpen, "phase \(phase)")
        let grid = model.geometry.grid

        // Panel › Height
        if grid.maxRows >= 2 {
            p.panelRows = 2
            await settle()
            check("Height set to 2 rows while open: the panel moves to 2 rows",
                  rows == 2 && model.mode == .grid && abs(glass.h.v - Double(grid.height(rows: 2))) < 0.01,
                  "rows \(rows), mode \(model.mode), height \(f(glass.h.v))")
        }
        p.panelRows = 1
        await settle()
        check("Height back to 1 row: the panel follows", rows == 1 && model.mode == .row && abs(glass.h.v - Double(grid.height(rows: 1))) < 0.01,
              "rows \(rows), height \(f(glass.h.v))")

        // Panel › Glass
        let classic: GlassSurface.Material = model.theme.reduceTransparency ? .opaque : .classic
        for (choice, want) in [(Preferences.Glass.solid, GlassSurface.Material.opaque), (.classic, classic), (.liquid, .glass)] {
            p.glass = choice
            check("Glass \(choice): the surface is \(want) at once", surface.material == want, "is \(surface.material)")
        }

        // Panel › Card buttons
        selectIndex(0)
        await settle()
        let other = model.clips[1].id
        p.cardButtons = .always
        check("Card buttons Always: an unselected card shows Copy and Remove", model.state(for: other).buttonsShown)
        p.cardButtons = .hoverAndSelected
        check("Card buttons Hover + selected: they hide again", !model.state(for: other).buttonsShown)

        // Motion › Card pop and Selection change
        if !rm {
            await wait(200)
            p.cardPop = 1.03
            let id1 = model.clips[1].id
            var peak = 1.0
            board.motions[id1]?.pop.probe = { peak = max(peak, $0) }
            key(kVK_RightArrow)
            await settle()
            board.motions[id1]?.pop.probe = nil
            check("Card pop 1.03: the selected card pops to 1.03", abs(peak - 1.03) < 0.001, "peak \(f(peak))")
            p.cardPop = 1.08

            await wait(200)
            p.selection = .flip
            key(kVK_RightArrow)
            check("Selection One-frame flip: the ring is on the new card at once",
                  !board.ring.busy && board.ring.cardID == model.selectedID && board.ring.ox.v == 0, "ring offset \(f(board.ring.ox.v))")
            await settle()
            await wait(200)
            p.selection = .slide
            key(kVK_RightArrow)
            check("Selection Sliding highlight: the ring slides to the new card", board.ring.busy && abs(board.ring.ox.v) > 1,
                  "ring offset \(f(board.ring.ox.v))")
            await settle()
            selectIndex(0)
            await settle()
        }

        // Motion › Reduce Motion and Slow motion
        let systemReduce = Motion.reduce
        p.reduceMotion = .always
        check("Reduce Motion Always on: the panel reduces motion at once", Motion.reduce && model.theme.reduceMotion)
        p.reduceMotion = .system
        check("Reduce Motion Follow system: back to the system's setting", Motion.reduce == systemReduce)
        p.slowMotion = true
        check("Slow motion ×5: the motion clock runs five times slower", MotionClock.shared.timeScale == max(5, DebugFlags.slowMotion))
        p.slowMotion = false
        check("Slow motion off: normal speed", MotionClock.shared.timeScale == DebugFlags.slowMotion)

        // Motion › Drag tilt
        if !rm {
            p.dragTilt = .fixed45
            var a = await lift(dx: 48, dy: 0)
            let fixed = drag?.preview.rot.v
            check("Drag tilt −45°: the lifted card leans −45°", drag != nil && abs((fixed ?? 0) + 45) < 0.5, "tilt \(f(fixed))")
            await drop(a)
            p.dragTilt = .speed
            a = await lift(dx: 48, dy: 0)
            let speed = drag?.preview.rot.v
            check("Drag tilt −6° + speed: the lifted card leans within −14…+2°", drag != nil && (speed.map { $0 >= -14 && $0 <= 2 } ?? false),
                  "tilt \(f(speed))")
            await drop(a)
        }

        // Motion › Panel while dragging out
        let up = CGFloat(model.geometry.cardHeight) + 80
        p.dragOut = .slide
        var a = await lift(dx: 0, dy: up)
        check("Slide away: the dragged-out panel slides out of sight",
              drag?.over == false && strip == .slid && (rm ? rise.op.dest == 0 : rise.y.dest > glass.h.v),
              "strip \(strip), drop \(f(rise.y.dest))")
        mouse(.leftMouseDragged, NSPoint(x: a.x, y: surface.frame.minY + 20))
        await settle()
        check("Slide away: back over the bottom edge, the panel rises back", strip == .full && rise.y.v == 0 && rise.op.v == 1,
              "strip \(strip), drop \(f(rise.y.v))")
        await drop(a)
        p.dragOut = .stay
        a = await lift(dx: 0, dy: up)
        check("Stay: the panel keeps its full height while the card is out",
              drag?.over == false && strip == .full && rise.y.v == 0 && abs(glass.h.v - targetHeight) < 0.01,
              "strip \(strip), height \(f(glass.h.v))")
        await drop(a)
        p.dragOut = .strip

        // Motion › After a drop: Close. Another app taking the card is played by ending the drag as
        // a session that copied.
        p.afterDrop = .close
        a = await lift(dx: 0, dy: up)
        if let d = drag {
            d.phase = .session
            sessionEnded(at: panel.convertPoint(toScreen: NSPoint(x: a.x, y: a.y + up)), operation: .copy)
        }
        await settle()
        while phase != .closed { await wait(16) }
        check("After a drop Close: the panel closes once another app takes the card", !isOpen && drag == nil, "phase \(phase)")
        mouse(.leftMouseUp, a)
        p.afterDrop = .growBack

        // Motion › Card entrance: the spread of the cards' fade at the frame the first is 30% in.
        func entranceSpread() async -> Double? {
            open()
            let cards = cardsInView()
            let start = CACurrentMediaTime()
            while let first = cards.first, first.op.v < 0.3, CACurrentMediaTime() - start < 2 { await wait(4) }
            let ops = cards.map(\.op.v)
            await settle()
            close()
            await settle()
            return cards.count > 1 ? (ops.max() ?? 0) - (ops.min() ?? 0) : nil
        }
        if !rm {
            p.entrance = .together
            let together = await entranceSpread()
            check("Card entrance Together: every card arrives at once", together.map { $0 < 0.02 } ?? true, "spread \(f(together))")
            p.entrance = .stagger
            let stagger = await entranceSpread()
            check("Card entrance 12 ms stagger: the cards arrive one after another", stagger.map { $0 > 0.1 } ?? true, "spread \(f(stagger))")
        }

        // General › Open the panel on
        p.openOn = .main
        check("Open the panel on Main screen: the screen with the menu bar", mouseScreen() == NSScreen.screens.first)
        p.openOn = .pointer

        // Panel › Appearance (applied by the app delegate)
        if DebugFlags.appearance == nil {
            p.appearance = .dark
            check("Appearance Dark: the app turns dark at once", NSApp.appearance?.name == .darkAqua)
            p.appearance = .system
            check("Appearance System: it follows the system again", NSApp.appearance == nil)
        }
        if isOpen { close() }
        await settle()
    }
}

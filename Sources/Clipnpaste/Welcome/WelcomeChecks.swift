import AppKit
import SwiftUI
import Carbon
import ClipnpasteCore

/// `--self-test`: the tour's navigation, the shortcut step and the last step, driven with
/// synthetic keys sent straight to its window. Nothing is posted to the system, the shortcut is
/// saved only in the sandboxed defaults and put back afterwards.
@MainActor
enum WelcomeSelfTest {
    static func run(shortcuts: ShortcutController, panel: PanelController,
                    show: (WelcomeStep) -> WelcomeController?) async -> Bool {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { passed += 1 } else { failed += 1 }
            debugLog("self-test \(ok ? "PASS" : "FAIL") welcome: \(name)\(ok ? "" : " — \(detail())")")
        }
        func key(_ w: WelcomeController, _ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "") {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: w.window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)) {
                w.window.sendEvent(e)
            }
        }
        func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func settle() async {
            let start = CACurrentMediaTime()
            await wait(40)
            while !MotionClock.shared.isIdle && CACurrentMediaTime() - start < 2 { await wait(16) }
            await wait(30)
        }

        // Navigation.
        guard let w = show(.welcome) else {
            check("opens", false, "no tour")
            return false
        }
        await settle()
        check("opens on step 1 with Back disabled", w.isVisible && w.step == .welcome && !w.backButton.isEnabled,
              "visible \(w.isVisible), step \(w.step.number), back \(w.backButton.isEnabled)")
        check("the picture plays while shown (stands still under Reduce Motion)", w.page?.running == !Motion.reduce)
        key(w, kVK_RightArrow); await settle()
        check("→ goes to step 2", w.step == .saved, "step \(w.step.number)")
        check("the old page has left", w.leavingCount == 0, "\(w.leavingCount) pages still leaving")
        key(w, kVK_Return); await settle()
        check("Return goes to step 3", w.step == .shortcut, "step \(w.step.number)")
        key(w, kVK_LeftArrow); await settle()
        check("← goes back to step 2", w.step == .saved, "step \(w.step.number)")
        key(w, kVK_LeftArrow); key(w, kVK_LeftArrow); await settle()
        check("← on step 1 stays there", w.step == .welcome && w.isVisible, "step \(w.step.number)")
        for _ in 0..<4 { key(w, kVK_RightArrow) }
        await settle()
        check("four quick → land on step 5, one page left", w.step == .paste && w.leavingCount == 0,
              "step \(w.step.number), leaving \(w.leavingCount)")
        check("Back is enabled after step 1", w.backButton.isEnabled)
        key(w, kVK_Escape); await settle()
        check("Esc skips: the tour closes", !w.window.isVisible && w.page == nil, "visible \(w.window.isVisible)")

        // The shortcut step: record, Esc cancels only the recording, Confirm saves.
        guard let s = show(.chooseShortcut), let field = s.page?.field else {
            check("opens on the shortcut step", false)
            return false
        }
        await settle()
        let original = shortcuts.shortcut
        s.window.makeFirstResponder(field)
        check("clicking the field records", field.isRecording && s.page?.recorderPhase == .recording)
        key(s, kVK_Escape); await settle()
        check("Esc while recording stops the recording, the tour stays", !field.isRecording && s.isVisible)
        s.window.makeFirstResponder(field)
        key(s, kVK_ANSI_K, [.option, .command], "k")
        let wanted = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: [.option, .command])
        let label = shortcuts.label(for: wanted)
        check("a new combination waits for Confirm", s.page?.pendingLabel == label && shortcuts.shortcut == original,
              "pending \(s.page?.pendingLabel ?? "nil"), saved \(shortcuts.label)")
        key(s, kVK_Return); await settle()
        check("Confirm saves it and goes on to Try it", shortcuts.shortcut == wanted && s.step == .tryIt,
              "saved \(shortcuts.label), step \(s.step.number)")
        check("Try it names the new shortcut", s.page?.shortcutLabel == label && s.nextButton.title == "Done")

        // The last step: the shortcut closes the tour and opens the panel, with the toast.
        key(s, kVK_ANSI_K, [.option, .command], "k")
        await settle()
        await wait(Int(650 * MotionClock.shared.timeScale))
        check("the shortcut on Try it closes the tour", !s.window.isVisible)
        check("and opens the panel", panel.isOpen, "phase \(panel.phase)")
        check("with \"You're all set\" above it", panel.toast.isVisible && panel.toast.frame.minY > panel.glassScreenRect.maxY,
              "toast \(panel.toast.frame), glass \(panel.glassScreenRect)")
        _ = shortcuts.reset()
        check("the shortcut is put back", shortcuts.isDefault)
        panel.close()
        let start = CACurrentMediaTime()
        while panel.phase != .closed && CACurrentMediaTime() - start < 3 { await wait(30) }
        await wait(Int(1900 * MotionClock.shared.timeScale))

        debugLog("self-test welcome done: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}

/// `--welcome-shots DIR`: every step's page drawn offscreen (no window ever shows), at its still
/// frame and a mid-motion frame, in the current appearance (`--appearance light|dark`), then the
/// app quits. `--welcome N` limits it to one step. Representable controls (the recorder field,
/// "Open Settings") don't draw offscreen; the window shows them.
@MainActor
enum WelcomeShots {
    static func render(into dir: String) {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dark = DebugFlags.appearance == "dark"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let label = Shortcut(keyCode: UInt32(Paster.vKeyCode()), modifiers: [.control, .command]).label(keyName: KeyNames.name)
        let theme = Theme(increaseContrast: DebugFlags.increaseContrast, reduceTransparency: DebugFlags.reduceTransparency,
                          reduceMotion: DebugFlags.reduceMotion)
        let steps = DebugFlags.welcomeStep.flatMap { WelcomeStep(number: $0) }.map { [$0] } ?? WelcomeStep.allCases
        let time = Sandbox.args.firstIndex(of: "--welcome-time").flatMap { i in Sandbox.args.indices.contains(i + 1) ? Double(Sandbox.args[i + 1]) : nil }
        for step in steps {
            let timing = VignetteTiming.of(step)
            let frames: [(String, Double)] = time.map { [("t\($0)", $0)] } ?? [("still", timing.still), ("mid", timing.shot)]
            for (name, t) in frames {
                let model = WelcomePageModel(step: step, theme: theme, shortcutLabel: label)
                model.frozen = t
                model.axGranted = WelcomeController.axGranted
                let view = WelcomePageView(model: model)
                    .frame(width: 480, height: 392)
                    .padding(40)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                var image: CGImage?
                appearance.performAsCurrentDrawingAppearance {
                    let r = ImageRenderer(content: view)
                    r.scale = 2
                    image = r.cgImage
                }
                guard let image else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                let file = url.appendingPathComponent(String(format: "%02d-%@-%@.png", step.number, name, dark ? "dark" : "light"))
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
                welcomeLog("rendered \(file.lastPathComponent)")
            }
        }
    }
}

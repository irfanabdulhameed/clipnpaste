import AppKit
import SwiftUI
import Carbon
import ClipnpasteCore

/// What the rest of the app gives the tour. The app delegate sets these at launch.
@MainActor
enum WelcomeHooks {
    /// Shows the tour from the start (Settings › About, the menu).
    static var show: (() -> Void)?
}

final class WelcomeWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The first-run welcome tour: a centred glass window, one feature per step, a progress bar,
/// Back / Next, Skip. Return and → go on, ← goes back, Esc skips. The last step waits for the
/// shortcut, then closes and opens the real panel.
///
/// Motion: the window materialises like the panel (opacity and 0.98 → 1 on `materialise`, a
/// 12 pt rise on `arrive`) and leaves accelerating. A step's page is born blurred (16 → 0 on
/// `settle`, opacity on `fadeIn`, 20 pt from the side it comes from) while the old page leaves
/// on `leave`, blurring and sliding the other way. Under Reduce Motion pages fade (out, then in)
/// and the pictures stand still.
@MainActor
final class WelcomeController: NSObject, NSWindowDelegate {
    static let card = NSSize(width: 560, height: 520)
    private static let margin: CGFloat = 40
    private static let pageFrame = NSRect(x: 40, y: 58, width: 480, height: 392)

    private let shortcuts: ShortcutController
    private let prefs = Preferences.app
    /// Called after the tour has left; `tried` when the shortcut was pressed on the last step.
    var onFinish: ((_ tried: Bool) -> Void)?

    let window: WelcomeWindow
    private let surface: GlassSurface
    private let content = WelcomeContentView()
    private let progress = WelcomeProgressView()
    private let counter = NSTextField(labelWithString: "")
    let skipButton = WelcomeButton(title: "Skip", style: .plain, help: "Close the tour (Esc)")
    let backButton = WelcomeButton(title: "Back", style: .secondary)
    let nextButton = WelcomeButton(title: "Next", style: .primary)

    private(set) var step: WelcomeStep = .welcome
    private(set) var page: WelcomePageModel?
    private var pageView: NSView?
    private var leaving: [NSView] = []
    private var pageFx: [ObjectIdentifier: PageFx] = [:]
    private lazy var windowFx = WindowFx { [weak self] fx in self?.surface.present(drop: fx.drop.v, opacity: fx.op.v, scale: fx.scale.v) }
    private var theme = Theme()
    private var axTimer: Timer?
    private var previousApp: NSRunningApplication?
    private(set) var isClosing = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    var isVisible: Bool { window.isVisible && !isClosing }
    /// Pages still on their way out, for the checks.
    var leavingCount: Int { leaving.count }

    init(shortcuts: ShortcutController) {
        self.shortcuts = shortcuts
        surface = GlassSurface(content: content, cornerRadius: 24, material: .glass)
        let m = Self.margin
        let size = NSSize(width: Self.card.width + 2 * m, height: Self.card.height + 2 * m)
        window = WelcomeWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.title = "Welcome to Clipnpaste"
        window.animationBehavior = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.onKey = { [weak self] in self?.handleKey($0) ?? false }
        window.onKeyEquivalent = { [weak self] e in
            guard let self, self.step == .tryIt, self.matchesShortcut(e) else { return false }
            self.tryIt()
            return true
        }
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        surface.frame = NSRect(x: m, y: m, width: Self.card.width, height: Self.card.height)
        root.addSubview(surface)
        window.contentView = root
        buildChrome()
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunning() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.applyDisplayOptions() } })
        observers.append(NotificationCenter.default.addObserver(forName: ShortcutController.didChange, object: shortcuts, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.page?.shortcutLabel = self?.shortcuts.label ?? "" }
        })
    }

    private func buildChrome() {
        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        counter.textColor = Palette.label3
        counter.alignment = .left
        for v in [progress, counter, skipButton, backButton, nextButton] as [NSView] { content.addSubview(v) }
        skipButton.target = self
        skipButton.action = #selector(skipClicked)
        backButton.target = self
        backButton.action = #selector(backClicked)
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        content.onLayout = { [weak self] in self?.layoutChrome() }
        progress.setAccessibilityElement(true)
        progress.setAccessibilityRole(.progressIndicator)
        progress.setAccessibilityLabel("Tour progress")
    }

    private func layoutChrome() {
        let w = Self.card.width, h = Self.card.height
        progress.frame = NSRect(x: 40, y: 31, width: 340, height: 4)
        counter.frame = NSRect(x: 392, y: 25, width: 70, height: 16)
        let skip = skipButton.intrinsicContentSize
        skipButton.frame = NSRect(x: w - 32 - skip.width, y: 20, width: skip.width, height: skip.height)
        let back = backButton.intrinsicContentSize, next = nextButton.intrinsicContentSize
        backButton.frame = NSRect(x: 40, y: h - 24 - WelcomeButton.height, width: back.width, height: WelcomeButton.height)
        nextButton.frame = NSRect(x: w - 40 - next.width, y: h - 24 - WelcomeButton.height, width: next.width, height: WelcomeButton.height)
        pageView?.frame = Self.pageFrame
    }

    // MARK: Show and close

    func show(at start: WelcomeStep = .welcome) {
        isClosing = false
        applyDisplayOptions()
        let front = NSWorkspace.shared.frontmostApplication
        if !window.isVisible, front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        go(to: start, direction: 0, animated: false)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let vf = screen.visibleFrame, f = window.frame
            window.setFrameOrigin(NSPoint(x: (vf.midX - f.width / 2).rounded(), y: (vf.midY - f.height / 2 + 20).rounded()))
        }
        MotionClock.shared.use(screen: window.screen ?? NSScreen.main)
        if Motion.reduce {
            windowFx.drop.set(0); windowFx.scale.set(1)
            windowFx.op.set(0); windowFx.op.tween(to: 1, ms: 150)
        } else {
            windowFx.drop.set(12); windowFx.drop.spring(to: 0, duration: Motion.arrive)
            windowFx.scale.set(Motion.materialiseScale)
            windowFx.scale.tween(to: 1, ms: Motion.materialiseMs, ease: Motion.materialise)
            windowFx.op.set(0)
            windowFx.op.tween(to: 1, ms: Motion.materialiseMs, ease: Motion.materialise)
        }
        MotionClock.shared.flush()
        if Sandbox.isOn {
            // Checks and screenshots never take the keyboard from the app in front.
            window.orderFrontRegardless()
        } else {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(nil)
        updateRunning()
        welcomeLog("shown on step \(step.number), window \(window.windowNumber), frame \(window.frame)")
    }

    /// Leaves accelerating, then orders out. `tried`: the shortcut was pressed on the last step.
    func close(tried: Bool = false) {
        guard !isClosing, window.isVisible else { return }
        isClosing = true
        stopRecording()
        axTimer?.invalidate()
        axTimer = nil
        page?.running = false
        if !Sandbox.isOn, let app = previousApp, !app.isTerminated { app.activate() }
        previousApp = nil
        let done: () -> Void = { [weak self] in
            guard let self, self.isClosing else { return }
            self.window.orderOut(nil)
            self.teardownPages()
            for o in self.observers { NotificationCenter.default.removeObserver(o) }
            for o in self.workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
            self.observers = []
            self.workspaceObservers = []
            welcomeLog("closed\(tried ? " by the shortcut" : "")")
            self.onFinish?(tried)
        }
        if Motion.reduce {
            windowFx.op.tween(to: 0, ms: 120, done: done)
        } else {
            windowFx.op.tween(to: 0, ms: 180, ease: Motion.leave, done: done)
            windowFx.drop.tween(to: 10, ms: 180, ease: Motion.leave)
            windowFx.scale.tween(to: Motion.materialiseScale, ms: 180, ease: Motion.leave)
        }
    }

    /// The hidden window costs nothing: its pages (and their pictures) are released.
    private func teardownPages() {
        for v in leaving { v.removeFromSuperview() }
        leaving.removeAll()
        pageView?.removeFromSuperview()
        pageView = nil
        page = nil
        pageFx.removeAll()
    }

    func windowWillClose(_ notification: Notification) { stopRecording() }

    // MARK: Steps

    @objc private func nextClicked() { next() }
    @objc private func backClicked() { back() }
    @objc private func skipClicked() { close() }

    func next() {
        guard !isClosing else { return }
        if step.isLast { close(); return }
        if step == .chooseShortcut, !confirmShortcut() { return }
        if let n = step.next { go(to: n, direction: 1, animated: true) }
    }

    func back() {
        guard !isClosing, let p = step.previous else { return }
        go(to: p, direction: -1, animated: true)
    }

    /// The last step: the shortcut was pressed. The tour leaves and the panel opens.
    func tryIt() {
        guard step == .tryIt, !isClosing else { return }
        close(tried: true)
    }

    private func go(to s: WelcomeStep, direction: Int, animated: Bool) {
        stopRecording()
        let old = pageView
        let oldModel = page
        oldModel?.running = false
        step = s
        let model = WelcomePageModel(step: s, theme: theme, shortcutLabel: shortcuts.label)
        model.still = theme.reduceMotion
        model.openAccessibility = { [weak self] in self?.openAccessibility() }
        if s == .chooseShortcut { wireRecorder(model) }
        if s == .accessibility { model.axGranted = Self.axGranted }
        let host = NSHostingView(rootView: WelcomePageView(model: model))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layerUsesCoreImageFilters = true
        host.frame = Self.pageFrame
        content.addSubview(host, positioned: .below, relativeTo: progress)
        page = model
        pageView = host
        // Keyboard focus inside the old page goes back to the window, so Return and the arrows work.
        if let r = window.firstResponder as? NSView, let old, r.isDescendant(of: old) { window.makeFirstResponder(nil) }

        let fx = PageFx(view: host)
        pageFx[ObjectIdentifier(host)] = fx
        if let old {
            leaving.append(old)
            leave(old, direction: direction, animated: animated)
        }
        if animated {
            fx.enter(direction: direction, after: old != nil)
        } else {
            fx.op.set(1); fx.blur.set(0); fx.x.set(0)
        }
        MotionClock.shared.flush()
        updateChrome(animated: animated)
        updateRunning()
        startAXPolling()
        welcomeLog("step \(s.number): \(s.title)")
    }

    private func leave(_ view: NSView, direction: Int, animated: Bool) {
        let id = ObjectIdentifier(view)
        let gone: () -> Void = { [weak self, weak view] in
            guard let self, let view else { return }
            view.removeFromSuperview()
            self.leaving.removeAll { $0 === view }
            self.pageFx[id] = nil
        }
        guard animated, let fx = pageFx[id] else { gone(); return }
        fx.leave(direction: direction, done: gone)
    }

    private func updateChrome(animated: Bool) {
        counter.stringValue = "\(step.number) of \(WelcomeStep.count)"
        progress.setAccessibilityValue("Step \(step.number) of \(WelcomeStep.count)")
        progress.set(Double(step.number) / Double(WelcomeStep.count), animated: animated)
        backButton.isEnabled = !step.isFirst
        nextButton.title = step.nextTitle
        skipButton.isHidden = step.isLast
        window.recalculateKeyViewLoop()
        layoutChrome()
    }

    private func updateRunning() {
        let visible = window.isVisible && window.occlusionState.contains(.visible) && !isClosing
        page?.running = visible && !theme.reduceMotion
        welcomeLog("pictures \(page?.running == true ? "running" : "paused")")
    }

    private func applyDisplayOptions() {
        let ws = NSWorkspace.shared
        theme = Theme(
            increaseContrast: DebugFlags.increaseContrast || ws.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: DebugFlags.reduceTransparency || ws.accessibilityDisplayShouldReduceTransparency,
            reduceMotion: DebugFlags.reduceMotion || ws.accessibilityDisplayShouldReduceMotion || prefs.reduceMotion == .always)
        Motion.reduce = theme.reduceMotion
        surface.material = theme.reduceTransparency || prefs.glass == .solid ? .opaque : (prefs.glass == .classic ? .classic : .glass)
        surface.increaseContrast = theme.increaseContrast
        page?.setTheme(theme)
        page?.still = theme.reduceMotion
        counter.textColor = theme.increaseContrast ? Palette.label3Contrast : Palette.label3
        progress.increaseContrast = theme.increaseContrast
        for b in [skipButton, backButton, nextButton] { b.needsDisplay = true }
        updateRunning()
    }

    // MARK: Keys

    /// Return and → go on, ← goes back, Esc skips; on the last step the shortcut opens the panel.
    func handleKey(_ e: NSEvent) -> Bool {
        if step == .tryIt, matchesShortcut(e) { tryIt(); return true }
        let flags = e.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return false }
        switch Int(e.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            nextButton.flashPress()
            next()
        case kVK_RightArrow: next()
        case kVK_LeftArrow: back()
        case kVK_Escape: close()
        default: return false
        }
        return true
    }

    func matchesShortcut(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: Shortcut.Modifiers = []
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.command) { mods.insert(.command) }
        return Shortcut(keyCode: UInt32(e.keyCode), modifiers: mods) == shortcuts.shortcut
    }

    // MARK: The shortcut step

    private func wireRecorder(_ model: WelcomePageModel) {
        let field = model.field
        field.label = shortcuts.label
        field.onRecordingChange = { [weak self, weak model] on in
            guard let self, let model else { return }
            if on {
                model.recorderPhase = .recording
                shortcuts.pauseHotKey()
            } else {
                shortcuts.resumeHotKey()
                if model.recorderPhase == .recording { model.recorderPhase = .rest }
            }
            field.phase = model.recorderPhase
        }
        field.onCandidate = { [weak self, weak model] s in
            guard let self, let model else { return }
            let label = shortcuts.label(for: s)
            model.pendingLabel = s == shortcuts.shortcut ? nil : label
            pending = s == shortcuts.shortcut ? nil : s
            field.label = label
            model.recorderPhase = .rest
            field.stopRecording()
            field.phase = .rest
            // Return now confirms instead of recording again.
            window.makeFirstResponder(nil)
        }
        field.onNeedsModifier = { [weak model] in
            model?.recorderPhase = .invalid
            field.phase = .invalid
        }
        field.onCancel = { [weak self] in
            guard let self else { return }
            if field.isRecording { field.stopRecording() }
            window.makeFirstResponder(nil)
        }
    }

    private var pending: Shortcut?

    /// Saves the chosen shortcut. False (and the step stays) when another app holds it.
    private func confirmShortcut() -> Bool {
        defer { pending = nil }
        guard let p = pending, let model = page else { return true }
        if shortcuts.apply(p) {
            model.pendingLabel = nil
            welcomeLog("shortcut saved: \(shortcuts.label)")
            return true
        }
        model.recorderPhase = .conflict
        model.field.phase = .conflict
        model.field.label = shortcuts.label
        model.pendingLabel = nil
        welcomeLog("shortcut refused: \(shortcuts.label(for: p)) is taken")
        return false
    }

    private func stopRecording() {
        guard let page, page.step == .chooseShortcut else { return }
        page.field.stopRecording()
        pending = nil
    }

    // MARK: Accessibility

    static var axGranted: Bool {
        if let i = Sandbox.args.firstIndex(of: "--welcome-ax"), Sandbox.args.indices.contains(i + 1) {
            return Sandbox.args[i + 1] == "granted"
        }
        return Paster.canPost
    }

    /// Polls once a second while the Accessibility step is on screen, so the status turns green
    /// as soon as it is allowed in System Settings.
    private func startAXPolling() {
        axTimer?.invalidate()
        axTimer = nil
        guard step == .accessibility else { return }
        axTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let page = self.page, page.step == .accessibility, self.window.isVisible else { return }
                let g = Self.axGranted
                if page.axGranted != g { page.axGranted = g }
            }
        }
    }

    private func openAccessibility() {
        if Sandbox.isOn {
            welcomeLog("would open Accessibility in System Settings")
        } else {
            Paster.openAccessibilitySettings()
        }
    }
}

// MARK: - Views and motion

/// The glass's content: flipped, laid out by the controller.
final class WelcomeContentView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// The progress bar: a 4 pt track with an accent fill that springs to each step.
@MainActor
final class WelcomeProgressView: NSView, MotionTarget {
    private let track = CALayer()
    private let fill = CALayer()
    private lazy var value = Anim(0, owner: self, eps: 0.0005)
    var increaseContrast = false { didSet { updateColors() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, fill] {
            l.cornerRadius = 2
            l.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(l)
        }
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(_ f: Double, animated: Bool) {
        if animated, !Motion.reduce { value.spring(to: f, duration: Motion.arrive) } else { value.set(f) }
        render()
    }

    func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        fill.frame = CGRect(x: 0, y: 0, width: (bounds.width * CGFloat(min(max(value.v, 0), 1))).rounded(), height: bounds.height)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = (increaseContrast ? Palette.ink(0.25, 0.3) : Palette.ink(0.08, 0.12)).cgColor
            fill.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }
}

/// A page's opacity, blur and sideways travel.
@MainActor
final class PageFx: MotionTarget {
    let op: Anim, blur: Anim, x: Anim
    private weak var view: NSView?

    init(view: NSView) {
        self.view = view
        op = Anim(1, owner: nil, eps: 0.002)
        blur = Anim(0, owner: nil, eps: 0.05)
        x = Anim(0, owner: nil, eps: 0.05)
        for a in [op, blur, x] { a.owner = self }
    }

    /// Born blurred, from the side it comes from; it starts as the old page is mostly gone.
    func enter(direction: Int, after: Bool) {
        if Motion.reduce {
            blur.set(0); x.set(0)
            op.set(0)
            op.tween(to: 1, ms: 150, delay: after ? 110 : 0)
            return
        }
        let d = after ? 70.0 : 0
        op.set(0); blur.set(16); x.set(20 * Double(direction))
        op.tween(to: 1, ms: 160, ease: Motion.fadeIn, delay: d)
        blur.spring(to: 0, duration: Motion.settle, delay: d)
        x.spring(to: 0, duration: Motion.arrive, delay: d)
    }

    /// Leaves accelerating: fades, blurs and slides the other way.
    func leave(direction: Int, done: @escaping () -> Void) {
        if Motion.reduce {
            op.tween(to: 0, ms: 100, done: done)
            return
        }
        op.tween(to: 0, ms: 150, ease: Motion.leave, done: done)
        blur.tween(to: 10, ms: 150, ease: Motion.leave)
        x.tween(to: -24 * Double(direction == 0 ? 1 : direction), ms: 150, ease: Motion.leave)
    }

    func render() {
        guard let layer = view?.layer else { return }
        LayerLook.opacity(layer, op.v)
        LayerLook.blur(layer, blur.v)
        let t = abs(x.v) > 0.01 ? CATransform3DMakeTranslation(CGFloat(x.v), 0, 0) : CATransform3DIdentity
        if !CATransform3DEqualToTransform(layer.transform, t) { layer.transform = t }
    }
}

/// The window's glass: its rise, scale and opacity.
@MainActor
final class WindowFx: MotionTarget {
    let op: Anim, drop: Anim, scale: Anim
    private let draw: (WindowFx) -> Void

    init(_ draw: @escaping (WindowFx) -> Void) {
        self.draw = draw
        op = Anim(1, owner: nil, eps: 0.002)
        drop = Anim(0, owner: nil, eps: 0.05)
        scale = Anim(1, owner: nil, eps: 0.0005)
        for a in [op, drop, scale] { a.owner = self }
    }

    func render() { draw(self) }
}

/// Tour check output: on for `--welcome`, the self-test and the renders.
func welcomeLog(_ message: String) {
    guard DebugFlags.welcomeStep != nil || DebugFlags.selfTest || DebugFlags.welcomeShots != nil else { return }
    FileHandle.standardError.write(Data("[Clipnpaste] welcome: \(message)\n".utf8))
}

import AppKit
import ClipnpasteCore

private enum RecorderColors {
    static let error = Palette.pair(NSColor(srgbRed: 0.70, green: 0.15, blue: 0.12, alpha: 1),
                                    NSColor(srgbRed: 1.0, green: 0.61, blue: 0.58, alpha: 1))
}

enum RecorderPhase { case rest, recording, saved, invalid, conflict }

/// The field that shows the shortcut and records the next combination.
/// Rest, hover, recording (focused), saved, invalid and conflict are all drawn here.
@MainActor
final class ShortcutField: NSView {
    var label = "" { didSet { setAccessibilityValue(label); needsDisplay = true } }
    var phase: RecorderPhase = .rest { didSet { needsDisplay = true } }
    private(set) var isRecording = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    var onRecordingChange: ((Bool) -> Void)?
    var onCandidate: ((Shortcut) -> Void)?
    var onNeedsModifier: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Shortcut")
        setAccessibilityHelp("Press to record a new shortcut")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 52) }

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        phase = .recording
        onRecordingChange?(true)
        needsDisplay = true
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        onRecordingChange?(false)
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        startRecording()
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder === self { startRecording() } else { window?.makeFirstResponder(self) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func keyDown(with event: NSEvent) { handle(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return false }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: Shortcut.Modifiers = []
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        let code = UInt32(event.keyCode)
        // Tab and Shift-Tab move focus, as they do everywhere else.
        if code == 48, mods.isDisjoint(with: [.command, .control, .option]) {
            if mods.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
            return
        }
        guard isRecording else {
            // Focused but not recording (after a save): Return or Space records again, Esc closes.
            if code == Shortcut.escapeKeyCode { onCancel?() }
            else if mods.isEmpty, code == 36 || code == 49 || code == 76 { startRecording() }
            return
        }
        switch Shortcut.check(keyCode: code, modifiers: mods) {
        case .cancel: onCancel?()
        case .needsModifier: onNeedsModifier?()
        case .valid: onCandidate?(Shortcut(keyCode: code, modifiers: mods))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = Theme(increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let focused = window?.firstResponder === self
        let rect = bounds
        let radius: CGFloat = 14
        let fill: NSColor = (hovering && !isRecording) ? Palette.buttonHover : Palette.button
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        var ring: NSColor?
        var width = theme.ringWidth
        switch phase {
        case .recording: ring = Palette.accentRing
        case .invalid, .conflict: ring = RecorderColors.error
        default:
            if focused { ring = Palette.accentRing; width = 1.5 }
        }
        if let ring {
            let inset = width / 2
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
            path.lineWidth = width
            ring.setStroke()
            path.stroke()
        }

        let recording = isRecording && phase == .recording
        let text = recording ? "Type a shortcut…" : label
        let font = recording ? NSFont.systemFont(ofSize: 15, weight: .medium) : NSFont.systemFont(ofSize: 22, weight: .semibold)
        let color = recording ? theme.nsLabel2 : Palette.label
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }
}

private extension Theme {
    var nsLabel2: NSColor { increaseContrast ? Palette.label2Contrast : Palette.label2 }
}

/// A pill (or round icon) button in the panel's button colours, with hover, pressed, focus and disabled.
@MainActor
final class GlassButton: NSButton {
    private var hovering = false
    private var tracking: NSTrackingArea?
    private let symbol: String?

    init(title: String, symbol: String? = nil, help: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel(help)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        if symbol != nil { return NSSize(width: 26, height: 26) }
        let w = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return NSSize(width: ceil(w) + 32, height: 30)
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        if isEnabled, [36, 49, 76].contains(Int(event.keyCode)) { performClick(nil) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = Theme(increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let rect = bounds
        let fill: NSColor
        if !isEnabled { fill = Palette.loadFill }
        else if isHighlighted { fill = Palette.buttonPress }
        else if hovering { fill = Palette.buttonHover }
        else { fill = Palette.button }
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()

        let textColor = !isEnabled ? Palette.label3 : Palette.label
        if let symbol, let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(.init(paletteColors: [theme.increaseContrast ? Palette.label2Contrast : Palette.label2]))
            if let image = base.withSymbolConfiguration(config) {
                let s = image.size
                image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: textColor]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
        if window?.firstResponder === self {
            let w = theme.ringWidth
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: w / 2, dy: w / 2), xRadius: rect.height / 2, yRadius: rect.height / 2)
            path.lineWidth = w
            Palette.accentRing.setStroke()
            path.stroke()
        }
    }
}

final class RecorderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

/// The small glass window behind "Shortcut…".
@MainActor
final class RecorderWindowController: NSObject, NSWindowDelegate {
    private static let card = NSSize(width: 340, height: 196)
    private static let margin: CGFloat = 40

    private let shortcuts: ShortcutController
    private let useClassicBlur: () -> Bool
    private let onClose: () -> Void
    private let window: RecorderWindow
    private let surface: GlassSurface
    private let field = ShortcutField()
    private let message = NSTextField(labelWithString: "")
    private let resetButton: GlassButton
    private let closeButton = GlassButton(title: "", symbol: "xmark", help: "Close")
    private var phase: RecorderPhase = .rest

    init(shortcuts: ShortcutController, useClassicBlur: @escaping () -> Bool, onClose: @escaping () -> Void) {
        self.shortcuts = shortcuts
        self.useClassicBlur = useClassicBlur
        self.onClose = onClose
        resetButton = GlassButton(title: "Reset to \(shortcuts.label(for: shortcuts.defaultShortcut))", help: "Reset the shortcut")
        let content = NSView()
        surface = GlassSurface(content: content, cornerRadius: 26, material: .glass)
        let m = Self.margin
        let size = NSSize(width: Self.card.width + 2 * m, height: Self.card.height + 2 * m)
        window = RecorderWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.title = "Shortcut"
        window.delegate = self
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        surface.frame = NSRect(x: m, y: m, width: Self.card.width, height: Self.card.height)
        root.addSubview(surface)
        window.contentView = root

        buildContent(content)
        wire()
    }

    private func buildContent(_ content: NSView) {
        let title = NSTextField(labelWithString: "Shortcut")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Palette.label
        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.alignment = .center
        message.lineBreakMode = .byTruncatingTail
        for v in [title, message] { v.translatesAutoresizingMaskIntoConstraints = false }
        field.translatesAutoresizingMaskIntoConstraints = false
        for v in [title, closeButton, field, message, resetButton] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 26),
            closeButton.heightAnchor.constraint(equalToConstant: 26),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 54),
            field.heightAnchor.constraint(equalToConstant: 52),
            message.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            message.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            message.heightAnchor.constraint(equalToConstant: 16),
            resetButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            resetButton.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 18),
            resetButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        // Tab order: field, then Reset, then close.
        field.nextKeyView = resetButton
        resetButton.nextKeyView = closeButton
        closeButton.nextKeyView = field
        window.initialFirstResponder = field
    }

    private func wire() {
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        resetButton.target = self
        resetButton.action = #selector(reset)
        field.onRecordingChange = { [weak self] on in
            guard let self else { return }
            if on { phase = .recording; shortcuts.pauseHotKey() } else {
                shortcuts.resumeHotKey()
                if phase != .saved { phase = .rest }
            }
            render()
        }
        field.onCandidate = { [weak self] s in
            guard let self else { return }
            if shortcuts.apply(s) {
                phase = .saved
                field.stopRecording()
            } else {
                phase = .conflict
            }
            render()
        }
        field.onNeedsModifier = { [weak self] in self?.phase = .invalid; self?.render() }
        field.onCancel = { [weak self] in self?.window.close() }
    }

    func show() {
        phase = .rest
        surface.material = useClassicBlur() ? .classic : .glass
        surface.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        render()
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Opens at rest; a click or Tab on the field starts recording.
        window.makeFirstResponder(nil)
        applyDebugState()
    }

    /// `--recorder-state recording|invalid|conflict|saved` shows a state for checks.
    private func applyDebugState() {
        let args = Sandbox.args
        guard let i = args.firstIndex(of: "--recorder-state"), args.indices.contains(i + 1) else { return }
        switch args[i + 1] {
        case "recording": window.makeFirstResponder(field)
        case "invalid": window.makeFirstResponder(field); phase = .invalid; render()
        case "conflict": window.makeFirstResponder(field); phase = .conflict; render()
        case "saved": window.makeFirstResponder(field); phase = .saved; field.stopRecording(); render()
        default: break
        }
    }

    private func render() {
        field.label = shortcuts.label
        field.phase = phase
        resetButton.isEnabled = !shortcuts.isDefault
        let (text, color): (String, NSColor)
        switch phase {
        case .rest: (text, color) = ("Click the field, then press a new shortcut", Palette.label3)
        case .recording: (text, color) = ("Press the keys you want, or Esc to cancel", Palette.label3)
        case .saved: (text, color) = ("Saved", Palette.label2)
        case .invalid: (text, color) = ("Include ⌘ or ⌃", RecorderColors.error)
        case .conflict: (text, color) = ("Another app uses this shortcut", RecorderColors.error)
        }
        message.stringValue = text
        message.textColor = color
    }

    @objc private func closeWindow() { window.close() }

    @objc private func reset() {
        phase = shortcuts.reset() ? .saved : .conflict
        render()
    }

    func windowWillClose(_ notification: Notification) {
        field.stopRecording()
        shortcuts.resumeHotKey()
        onClose()
    }
}

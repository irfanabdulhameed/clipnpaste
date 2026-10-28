import AppKit
import SwiftUI

/// The tour's buttons, in the panel's button language: a pill with one-frame fill flips.
/// Rest, hover (fill flips, a small 1.03 pop), pressed (fill flips darker, dips to 0.96 and holds
/// until release), keyboard focus (the accent ring), disabled (faded, no hover). Under Reduce
/// Motion the press only darkens and nothing scales.
@MainActor
final class WelcomeButton: NSButton, MotionTarget {
    enum Style { case primary, secondary, plain }

    let style: Style
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var pressing = false { didSet { if pressing != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    private lazy var scaleAnim = Anim(1, owner: self, eps: 0.0005)

    static let height: CGFloat = 30
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    init(title: String, style: Style, help: String? = nil) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(title)
        if let help { toolTip = help }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var title: String {
        didSet { invalidateIntrinsicContentSize(); setAccessibilityLabel(title); needsDisplay = true }
    }
    override var isEnabled: Bool { didSet { if !isEnabled { hovering = false }; needsDisplay = true } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let w = ceil((title as NSString).size(withAttributes: [.font: Self.font]).width)
        switch style {
        case .plain: return NSSize(width: w + 20, height: 26)
        default: return NSSize(width: max(w + 32, 84), height: Self.height)
        }
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        hovering = true
        if !Motion.reduce, !pressing { scaleAnim.pop(1.03) }
    }

    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Held down: dips and holds; released: springs back. The tracking loop runs inside super.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        press(true)
        super.mouseDown(with: event)
        press(false)
    }

    /// Space presses the focused button; Return and the arrows go on to the window (Next, Back).
    override func keyDown(with event: NSEvent) {
        if isEnabled, event.keyCode == 49 {
            press(true)
            performClick(nil)
            press(false)
        } else {
            super.keyDown(with: event)
        }
    }

    /// A press from the keyboard or the window (Return): the same dip, then back.
    func flashPress() {
        guard isEnabled else { return }
        press(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * MotionClock.shared.timeScale) { [weak self] in self?.press(false) }
    }

    private func press(_ down: Bool) {
        pressing = down
        guard !Motion.reduce else { scaleAnim.set(1); return }
        if down {
            scaleAnim.tween(to: 0.96, ms: Motion.dipMs, ease: Motion.popUp)
        } else {
            scaleAnim.spring(to: 1, duration: Motion.quick)
        }
    }

    func render() { LayerLook.scale(self, scaleAnim.v) }

    override func draw(_ dirtyRect: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || DebugFlags.increaseContrast
        let rect = bounds
        let r = rect.height / 2
        let down = pressing || isHighlighted
        let shape = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        var text: NSColor
        switch style {
        case .primary:
            let accent = NSColor.controlAccentColor
            let fill: NSColor
            if !isEnabled { fill = Palette.loadFill }
            else if down { fill = accent.blended(withFraction: 0.22, of: .black) ?? accent }
            else if hovering { fill = accent.blended(withFraction: 0.12, of: .white) ?? accent }
            else { fill = accent }
            fill.setFill()
            shape.fill()
            text = isEnabled ? .white : Palette.label3
        case .secondary:
            let fill: NSColor
            if !isEnabled { fill = Palette.loadFill }
            else if down { fill = Palette.buttonPress }
            else if hovering { fill = Palette.buttonHover }
            else { fill = Palette.button }
            fill.setFill()
            shape.fill()
            if contrast, isEnabled {
                NSColor.separatorColor.setStroke()
                let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
                edge.lineWidth = 1
                edge.stroke()
            }
            text = isEnabled ? Palette.label : Palette.label3
        case .plain:
            if isEnabled, down || hovering {
                (down ? Palette.buttonHover : Palette.button).setFill()
                shape.fill()
            }
            text = !isEnabled ? Palette.label3 : (hovering || down) ? Palette.label : (contrast ? Palette.label2Contrast : Palette.label2)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: text]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded()),
                                 withAttributes: attrs)
        if window?.firstResponder === self, window?.isKeyWindow == true {
            let w: CGFloat = contrast ? 3.5 : 2.5
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: w / 2, dy: w / 2), xRadius: r - w / 2, yRadius: r - w / 2)
            ring.lineWidth = w
            Palette.accentRing.setStroke()
            ring.stroke()
        }
    }
}

/// A WelcomeButton inside the SwiftUI page (the Accessibility step's "Open Settings").
struct WelcomeButtonControl: NSViewRepresentable {
    let title: String
    var style: WelcomeButton.Style = .secondary
    let action: () -> Void

    func makeNSView(context: Context) -> WelcomeButton {
        let b = WelcomeButton(title: title, style: style)
        b.target = context.coordinator
        b.action = #selector(Coordinator.fire)
        return b
    }

    func updateNSView(_ b: WelcomeButton, context: Context) {
        if b.title != title { b.title = title }
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WelcomeButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

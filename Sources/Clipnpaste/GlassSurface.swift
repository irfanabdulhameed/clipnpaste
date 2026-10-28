import AppKit

/// A rounded sheet of material with its own shadow, holding one content view.
/// Liquid Glass by default; behind-window blur when "Use classic blur" is on; opaque under
/// Reduce Transparency in classic mode (the glass gets frostier by itself).
@MainActor
final class GlassSurface: NSView {
    enum Material: Equatable { case glass, classic, opaque }

    let content: NSView
    let cornerRadius: CGFloat
    private let shadowView = NSView()
    private let borderView = NonHitView()
    private let shadowMask = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private var materialView: NSView?

    var material: Material { didSet { if material != oldValue { rebuild() } } }
    var increaseContrast = false { didSet { if increaseContrast != oldValue { updateColors() } } }

    init(content: NSView, cornerRadius: CGFloat, material: Material) {
        self.content = content
        self.cornerRadius = cornerRadius
        self.material = material
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        shadowView.wantsLayer = true
        shadowView.autoresizingMask = [.width, .height]
        if let l = shadowView.layer {
            l.masksToBounds = false
            l.shadowColor = NSColor.black.cgColor
            l.shadowOffset = CGSize(width: 0, height: -6)
            l.shadowRadius = 12
            shadowMask.fillRule = .evenOdd
            l.mask = shadowMask
        }
        addSubview(shadowView)

        borderView.wantsLayer = true
        borderView.autoresizingMask = [.width, .height]
        borderLayer.fillColor = nil
        borderView.layer?.addSublayer(borderLayer)

        content.autoresizingMask = [.width, .height]
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        materialView?.frame = bounds
        if material != .glass { content.frame = bounds }
        let path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowView.layer?.shadowPath = path
        // The shadow shows only outside the sheet, as a CSS box-shadow does, so it never darkens the glass.
        let room: CGFloat = 60
        shadowMask.frame = bounds.insetBy(dx: -room, dy: -room)
        let maskPath = CGMutablePath()
        maskPath.addRect(shadowMask.bounds)
        maskPath.addPath(path, transform: CGAffineTransform(translationX: room, y: room))
        shadowMask.path = maskPath
        borderLayer.frame = bounds
        let inset = borderLayer.lineWidth / 2
        borderLayer.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                  cornerWidth: cornerRadius - inset, cornerHeight: cornerRadius - inset, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Where the sheet is drawn while it rises or leaves: `drop` points below its frame, at
    /// `opacity`. A transform and an opacity on its own layer, so neither the view's frame nor
    /// the window moves, and the glass is never filtered. At rest: identity and 1.
    /// `scale` grows the sheet about its centre (1 at rest).
    func present(drop: CGFloat, opacity: Double, scale: Double = 1) {
        guard let layer else { return }
        let down: CGFloat = (layer.superlayer?.isGeometryFlipped ?? false) ? 1 : -1
        var t = CardCell.scale(scale, about: CGPoint(x: bounds.midX, y: bounds.midY),
                               anchor: layer.anchorPoint, size: bounds.size)
        if drop != 0 { t = CATransform3DConcat(t, CATransform3DMakeTranslation(0, down * drop, 0)) }
        if !CATransform3DEqualToTransform(layer.transform, t) { layer.transform = t }
        LayerLook.opacity(layer, opacity)
    }

    private func rebuild() {
        materialView?.removeFromSuperview()
        content.removeFromSuperview()
        // The glass view moves its content to Auto Layout; the other surfaces size it by frame.
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        let view: NSView
        switch material {
        case .glass:
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            content.frame = glass.bounds
            view = glass
        case .classic:
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = Self.roundedMask(cornerRadius)
            content.frame = blur.bounds
            blur.addSubview(content)
            view = blur
        case .opaque:
            let plain = NSView(frame: bounds)
            plain.wantsLayer = true
            plain.layer?.cornerRadius = cornerRadius
            plain.layer?.cornerCurve = .continuous
            plain.layer?.masksToBounds = true
            content.frame = plain.bounds
            plain.addSubview(content)
            view = plain
        }
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .above, relativeTo: shadowView)
        materialView = view
        borderView.frame = bounds
        addSubview(borderView, positioned: .above, relativeTo: view)
        updateColors()
        needsLayout = true
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            shadowView.layer?.shadowOpacity = dark ? 0.40 : 0.18
            if material == .opaque {
                materialView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            // The glass draws its own rim, and its own contrast border under Increase Contrast.
            if material == .glass {
                borderLayer.lineWidth = 0
                borderLayer.strokeColor = nil
            } else if increaseContrast {
                borderLayer.lineWidth = 1
                borderLayer.strokeColor = NSColor.separatorColor.cgColor
            } else {
                borderLayer.lineWidth = 0.5
                borderLayer.strokeColor = Palette.edge.cgColor
            }
        }
        needsLayout = true
    }

    private static func roundedMask(_ r: CGFloat) -> NSImage {
        let side = r * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}

/// A view that draws but never takes the mouse.
final class NonHitView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

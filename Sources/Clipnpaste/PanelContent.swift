import AppKit
import SwiftUI
import ClipnpasteCore

/// A layer that never animates by itself: every change is either instant or driven by Motion.
final class StillLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }
}

/// What sits inside the glass, top-down: the 28 pt top bar (status, pill, History), then the cards.
@MainActor
final class PanelContentView: NSView {
    let topBar: TopBarView
    /// Holds the scroll view and the empty state; fades and blurs as one while the panel is a strip.
    let cardsArea = NSView()
    let scrollView = NSScrollView()
    let documentView = CardsDocumentView()
    let emptyHost: NSHostingView<EmptyState>

    init(model: PanelModel) {
        topBar = TopBarView(model: model)
        emptyHost = NSHostingView(rootView: EmptyState(model: model))
        super.init(frame: .zero)
        wantsLayer = true

        cardsArea.wantsLayer = true
        cardsArea.layerUsesCoreImageFilters = true
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.usesPredominantAxisScrolling = true
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.wantsLayer = true
        scrollView.documentView = documentView
        emptyHost.sizingOptions = []
        cardsArea.addSubview(scrollView)
        cardsArea.addSubview(emptyHost)
        addSubview(cardsArea)
        addSubview(topBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func layout() {
        super.layout()
        place()
    }

    /// Fixed to the top of the glass, so a growing glass uncovers rows from the top bar down.
    private func place() {
        let w = bounds.width, h = bounds.height
        let top = CGFloat(PanelGrid.scrollTop)
        topBar.frame = NSRect(x: 0, y: 0, width: w, height: CGFloat(CardLayout.topBar))
        cardsArea.frame = NSRect(x: 0, y: top, width: w, height: max(h - top, 0))
        scrollView.frame = cardsArea.bounds
        if let g = topBar.geometry {
            emptyHost.frame = NSRect(x: 0, y: CGFloat(PanelGrid.contentTop), width: w, height: CGFloat(g.cardHeight))
        }
    }
}

/// The document of the cards' scroll view.
@MainActor
final class CardsDocumentView: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: Cards

/// One card in the scroll content: the day-1 SwiftUI card, hosted in a layer-backed view the
/// motion code places, scales, fades and blurs. A margin around the card leaves room for the
/// selection ring and for blur to spread.
@MainActor
final class CardCell: NSView {
    static let margin: CGFloat = 24

    private let host: NSHostingView<CardCellContent>
    private(set) var clipID: UUID?
    private let model: PanelModel
    private var blurFilter: CIFilter?
    private var lastBlur: Double = 0

    init(model: PanelModel) {
        self.model = model
        host = NSHostingView(rootView: CardCellContent(clip: nil, model: model))
        host.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ clip: Clip) {
        guard clipID != clip.id else { return }
        clipID = clip.id
        host.rootView = CardCellContent(clip: clip, model: model)
    }

    func clear() {
        clipID = nil
        host.rootView = CardCellContent(clip: nil, model: model)
    }

    /// Puts the card's top-left at (`x`, `y`) in the scroll content.
    func place(x: Double, y: Double, size: CGSize, scale: Double, opacity: Double, blur: Double) {
        let m = Self.margin
        let f = NSRect(x: CGFloat(x) - m, y: CGFloat(y) - m, width: size.width + 2 * m, height: size.height + 2 * m)
        if frame != f { frame = f }
        if host.frame.size != f.size { host.frame = NSRect(origin: .zero, size: f.size) }
        guard let layer else { return }
        layer.transform = Self.scale(scale, about: CGPoint(x: f.width / 2, y: f.height / 2), anchor: layer.anchorPoint, size: f.size)
        layer.opacity = Float(min(max(opacity, 0), 1))
        setBlur(blur)
    }

    private func setBlur(_ r: Double) {
        guard abs(r - lastBlur) > 0.01 || (r <= 0.05) != (lastBlur <= 0.05) else { return }
        lastBlur = r
        if r <= 0.05 {
            // Every blur ends at exactly 0 and the filter goes, so cards at rest are pixel-crisp.
            if layer?.filters != nil { layer?.filters = nil }
            return
        }
        let f = blurFilter ?? CIFilter(name: "CIGaussianBlur")!
        f.setValue(r / 2, forKey: kCIInputRadiusKey)
        blurFilter = f
        layer?.filters = [f]
    }

    static func scale(_ s: Double, about c: CGPoint, anchor: CGPoint, size: CGSize) -> CATransform3D {
        guard abs(s - 1) > 1e-4 else { return CATransform3DIdentity }
        let p = CGPoint(x: c.x - anchor.x * size.width, y: c.y - anchor.y * size.height)
        var t = CATransform3DMakeTranslation(-p.x, -p.y, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(CGFloat(s), CGFloat(s), 1))
        return CATransform3DConcat(t, CATransform3DMakeTranslation(p.x, p.y, 0))
    }
}

struct CardCellContent: View {
    let clip: Clip?
    let model: PanelModel

    var body: some View {
        if let clip {
            CardView(clip: clip, state: model.state(for: clip.id), geometry: model.geometry, theme: model.theme,
                     now: model.now, onMissing: { model.markMissing($0) })
                .padding(CardCell.margin)
        }
    }
}

/// A day header in history ("Today", "Yesterday", "Monday 26 October"): Subheadline semibold.
@MainActor
final class DayHeaderView: NSView {
    let label = NSTextField(labelWithString: "")
    private var blurFilter: CIFilter?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(text: String, color: NSColor) {
        if label.stringValue != text { label.stringValue = text }
        label.textColor = color
    }

    func place(x: CGFloat, y: Double, width: CGFloat, opacity: Double, blur: Double) {
        let h = CGFloat(PanelGrid.headerHeight)
        frame = NSRect(x: x, y: CGFloat(y), width: width, height: h)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 0, y: ((h - size.height) / 2).rounded(), width: width, height: size.height)
        layer?.opacity = Float(min(max(opacity, 0), 1))
        if blur <= 0.05 {
            if layer?.filters != nil { layer?.filters = nil }
        } else {
            let f = blurFilter ?? CIFilter(name: "CIGaussianBlur")!
            f.setValue(blur / 2, forKey: kCIInputRadiusKey)
            blurFilter = f
            layer?.filters = [f]
        }
    }
}

/// A plain card fill shown where older clips are still loading in history. No shimmer.
@MainActor
final class PlaceholderCardView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PanelGeometry.cardRadius
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.loadFill.cgColor
        }
    }
}

// MARK: Top bar

/// 28 pt: the status slot on the left, the resize pill in the centre, History on the right.
@MainActor
final class TopBarView: NSView {
    let statusHost: NSHostingView<StatusSlot>
    let pill = PillView()
    let history = HistoryButtonView()
    private(set) var geometry: PanelGeometry?
    private let model: PanelModel

    init(model: PanelModel) {
        self.model = model
        statusHost = NSHostingView(rootView: StatusSlot(model: model))
        statusHost.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(statusHost)
        addSubview(pill)
        addSubview(history)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    func use(_ g: PanelGeometry) {
        geometry = g
        place()
    }

    private func place() {
        let w = bounds.width, h = CGFloat(CardLayout.topBar)
        statusHost.frame = NSRect(x: 14, y: 0, width: max(w / 2 - 76 - 14, 0), height: h)
        pill.frame = PillView.hitRect(panelWidth: w)
        history.frame = HistoryButtonView.rect(panelWidth: w)
    }

    /// The parts that fade while the panel is a strip (the pill stays).
    func setSidesOpacity(_ o: Double) {
        let a = Float(min(max(o, 0), 1))
        statusHost.layer?.opacity = a
        history.layer?.opacity = a
        statusHost.isHidden = o < 0.01
        history.isHidden = o < 0.01
    }
}

/// The resize pill: a 36 × 5 capsule centred 12 pt below the glass top, in a 120 × 24 hit area.
@MainActor
final class PillView: NSView, MotionTarget {
    enum Look: Equatable { case rest, hover, pressed }

    private let capsule = StillLayer()
    /// Pop and dip.
    private(set) var scale: Anim!
    /// Moves the capsule down while the panel is a strip (0 → 8 pt).
    var shiftY: CGFloat = 0 { didSet { if shiftY != oldValue { render() } } }
    var increaseContrast = false { didSet { updateColor() } }
    private(set) var look: Look = .rest

    static func hitRect(panelWidth w: CGFloat) -> NSRect {
        NSRect(x: (w / 2 - 60).rounded(.down), y: 0, width: 120, height: 24)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        scale = Anim(1, owner: self, eps: 0.0005)
        capsule.cornerCurve = .continuous
        layer?.addSublayer(capsule)
        toolTip = "Drag to resize"
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Drag to resize")
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Hover and pressed are one-frame flips; hover adds the 1.08 pop, press the 0.94 dip.
    func setLook(_ l: Look) {
        guard l != look else { return }
        let old = look
        look = l
        updateColor()
        render()
        guard !Motion.reduce else { return }
        switch (old, l) {
        case (.rest, .hover): scale.pop()
        case (_, .pressed): scale.tween(to: Motion.dipPill, ms: Motion.dipMs, ease: Motion.popUp)
        case (.pressed, _): scale.spring(to: 1, duration: Motion.quick)
        default: break
        }
    }

    func render() {
        let w: CGFloat = look == .rest ? 36 : 44
        capsule.bounds = CGRect(x: 0, y: 0, width: w, height: 5)
        capsule.cornerRadius = 2.5
        // The pill's layer is y-up inside a flipped view only when AppKit flips it; place by the view's geometry.
        let flipped = layer?.isGeometryFlipped ?? false
        let top = 10 + shiftY
        let y = flipped ? top + 2.5 : bounds.height - top - 2.5
        capsule.position = CGPoint(x: bounds.width / 2, y: y)
        let s = CGFloat(scale?.v ?? 1)
        capsule.transform = abs(s - 1) > 1e-4 ? CATransform3DMakeScale(s, s, 1) : CATransform3DIdentity
    }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        let c: NSColor
        switch look {
        case .rest: c = increaseContrast ? Palette.pillContrast : Palette.pill
        case .hover: c = Palette.pillHover
        case .pressed: c = Palette.pillPress
        }
        effectiveAppearance.performAsCurrentDrawingAppearance { capsule.backgroundColor = c.cgColor }
    }
}

/// The History button: a 22 pt circle 12 pt from the right edge, 3 pt from the top.
@MainActor
final class HistoryButtonView: NSView, MotionTarget {
    private let disc = StillLayer()
    private let ring = StillLayer()
    private let symbol = StillLayer()
    private(set) var scale: Anim!

    var hovered = false { didSet { if hovered != oldValue { changed(hoverPop: hovered) } } }
    var pressed = false { didSet { if pressed != oldValue { pressChanged() } } }
    var selected = false { didSet { if selected != oldValue { changed() } } }
    var enabled = true { didSet { if enabled != oldValue { changed() } } }
    var focused = false { didSet { if focused != oldValue { changed() } } }

    static func rect(panelWidth w: CGFloat) -> NSRect { NSRect(x: w - 12 - 22, y: 3, width: 22, height: 22) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        scale = Anim(1, owner: self, eps: 0.0005)
        for l in [ring, disc, symbol] { layer?.addSublayer(l) }
        ring.borderWidth = 3
        ring.backgroundColor = nil
        toolTip = "History (⌘Y)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("History")
        changed()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        changed()
    }

    override func layout() {
        super.layout()
        render()
    }

    private func pressChanged() {
        changed()
        guard !Motion.reduce else { return }
        if pressed {
            scale.tween(to: Motion.dipControl, ms: Motion.dipMs, ease: Motion.popUp)
        } else {
            scale.spring(to: 1, duration: Motion.quick)
        }
    }

    /// Every state change is a one-frame flip; hover adds the 1.08 pop.
    private func changed(hoverPop: Bool = false) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor?
            let tint: NSColor
            if selected {
                fill = .controlAccentColor
                tint = .white
            } else if !enabled {
                fill = nil
                tint = Palette.label2
            } else if pressed {
                fill = Palette.buttonPress
                tint = Palette.label
            } else if hovered {
                fill = Palette.button
                tint = Palette.label
            } else {
                fill = nil
                tint = Palette.label2
            }
            disc.backgroundColor = fill?.cgColor
            ring.borderColor = Palette.accentRing.cgColor
            ring.isHidden = !focused
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(.init(paletteColors: [tint]))
            if let img = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "History")?
                .withSymbolConfiguration(config) {
                let scale = window?.backingScaleFactor ?? 2
                symbol.contents = img.layerContents(forContentsScale: scale)
                symbol.contentsScale = scale
                symbol.bounds = CGRect(origin: .zero, size: img.size)
            }
        }
        layer?.opacity = enabled ? 1 : 0.45
        setAccessibilityValue(selected ? "On" : "Off")
        if hoverPop && !Motion.reduce && enabled { scale.pop() }
        render()
    }

    func render() {
        let b = bounds
        let c = CGPoint(x: b.midX, y: b.midY)
        disc.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        disc.cornerRadius = 11
        disc.position = c
        ring.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        ring.cornerRadius = 14
        ring.position = c
        symbol.position = c
        let s = CGFloat(scale?.v ?? 1)
        let t = abs(s - 1) > 1e-4 ? CATransform3DMakeScale(s, s, 1) : CATransform3DIdentity
        disc.transform = t
        symbol.transform = t
        ring.transform = t
    }
}

// MARK: SwiftUI parts

/// The top bar's left slot: the History title and count, or a banner, or nothing.
struct StatusSlot: View {
    let model: PanelModel

    var body: some View {
        let theme = model.theme
        Group {
            if model.mode == .history {
                HStack(spacing: 8) {
                    Text("History")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.label)
                    Text(Self.count(model.totalCount))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.label2)
                }
                .lineLimit(1)
            } else if model.needsAccessibility {
                AccessibilityBanner(theme: theme) { model.onOpenSettings?() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// "1,284 clips".
    static func count(_ n: Int) -> String {
        "\(n.formatted(.number.locale(Locale(identifier: "en_GB")))) \(n == 1 ? "clip" : "clips")"
    }
}

/// First use, or an empty history.
struct EmptyState: View {
    let model: PanelModel

    var body: some View {
        if model.clips.isEmpty {
            if model.mode == .history {
                Text("No clips yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(model.theme.label2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyRow(theme: model.theme)
            }
        }
    }
}

import SwiftUI
import ClipnpasteCore

/// One clip in the row. A pure picture of its clip and state: the panel controller does all input.
/// The card's own position, scale, fade and blur (and the selection ring) live on its cell's layer;
/// the motion inside it (the buttons' pop and dip, the thumbnail's blur-in) comes from `look`.
struct CardView: View {
    let clip: Clip
    let state: CardState
    let geometry: PanelGeometry
    let theme: Theme
    let now: Date
    var onMissing: (UUID) -> Void = { _ in }
    /// The drag preview: an opaque card with no ring and no buttons.
    var preview = false
    var look: CardLook?

    private var w: CGFloat { CGFloat(geometry.cardWidth) }
    private var h: CGFloat { CGFloat(geometry.cardHeight) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelGeometry.cardRadius, style: .continuous)
        let header = CGFloat(PanelGeometry.header), footer = CGFloat(PanelGeometry.footer)
        // Under Reduce Motion a press darkens instead of dipping.
        let darkPress = state.pressed && theme.reduceMotion
        ZStack(alignment: .topLeading) {
            shape.fill(preview ? theme.previewFill : theme.cardFill)
            shape.strokeBorder(theme.cardHair, lineWidth: 0.5)
            if let border = theme.cardBorder { shape.strokeBorder(border, lineWidth: 1) }
            if darkPress {
                shape.fill(theme.press)
            } else if state.hovered {
                shape.fill(theme.hover)
            }

            switch clip.kind {
            case .text:
                Text(ClipText.preview(clip.plainText ?? ""))
                    .font(.system(size: 13))
                    .lineHeight(.exact(points: CGFloat(PanelGeometry.lineHeight)))
                    .foregroundStyle(theme.label)
                    .lineLimit(geometry.lines)
                    .truncationMode(.tail)
                    .frame(width: w - 20, height: CGFloat(geometry.lines * PanelGeometry.lineHeight), alignment: .topLeading)
                    .offset(x: 10, y: header)
                footerText(ClipText.characters(clip.characterCount))
                    .offset(x: 10, y: h - footer)
            case .image:
                let bottom: CGFloat = state.missing ? 22 : 6
                ThumbView(clip: clip, missing: state.missing, theme: theme,
                          box: CGSize(width: w - 12, height: h - header - 6), onMissing: onMissing, look: look)
                    .frame(width: w - 12, height: h - header - bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(state.missing ? 0.45 : 1)
                    .offset(x: 6, y: header)
                if state.missing {
                    footerText("File missing").offset(x: 10, y: h - footer)
                }
            }

            headerRow.frame(width: w, height: header)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClipText.spoken(clip, now: now, missing: state.missing))
        .accessibilityAddTraits(state.selected ? .isSelected : [])
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(nsImage: AppIcons.icon(for: clip.sourceBundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            Text(ClipText.time(clip.createdAt, now: now))
                .font(.system(size: 11))
                .foregroundStyle(theme.label2)
                .lineLimit(1)
            Spacer(minLength: 0)
            if state.buttonsShown && !preview {
                HStack(spacing: 4) {
                    CardButtonView(
                        symbol: copySymbol, help: "Copy",
                        hovered: state.hoveredButton == .copy, pressed: state.pressedButton == .copy,
                        focused: state.focus == .copy, disabled: state.missing, theme: theme,
                        look: look, button: .copy)
                    CardButtonView(
                        symbol: "xmark", help: "Remove",
                        hovered: state.hoveredButton == .remove, pressed: state.pressedButton == .remove,
                        focused: state.focus == .remove, disabled: false, theme: theme,
                        look: look, button: .remove)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
    }

    /// The checkmark (or the warning) is a hard cut, never a crossfade.
    private var copySymbol: String {
        switch state.mark {
        case .done: "checkmark"
        case .failed: "exclamationmark.triangle"
        case nil: "doc.on.doc"
        }
    }

    private func footerText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(theme.label3)
            .lineLimit(1)
            .frame(width: w - 20, height: CGFloat(PanelGeometry.footer), alignment: .leading)
    }
}

/// The 20 pt round copy and remove buttons. Hover flips the fill and pops 1.08; a press dips to
/// 0.92 and holds (under Reduce Motion it darkens instead). The scale comes from the card's look.
struct CardButtonView: View {
    let symbol: String
    let help: String
    let hovered: Bool
    let pressed: Bool
    let focused: Bool
    let disabled: Bool
    let theme: Theme
    var look: CardLook?
    var button: CardButton = .copy

    var body: some View {
        let darkPress = pressed && theme.reduceMotion
        let lit = (hovered || pressed) && !disabled
        let fill = disabled ? theme.button : darkPress ? theme.buttonPress : lit ? theme.buttonHover : theme.button
        ZStack {
            Circle().fill(fill)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(lit ? theme.label : theme.label2)
                .contentTransition(.identity)
        }
        .frame(width: 20, height: 20)
        .background {
            if focused { Circle().strokeBorder(theme.accentRing, lineWidth: 3).frame(width: 26, height: 26) }
        }
        .scaleEffect(look?.scale(button) ?? 1)
        .opacity(disabled ? 0.45 : 1)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An image card's thumbnail: a plain fill while it loads, then the picture, born blurred when it
/// arrives on screen.
struct ThumbView: View {
    let clip: Clip
    let missing: Bool
    let theme: Theme
    let box: CGSize
    let onMissing: (UUID) -> Void
    let look: CardLook?
    @State private var thumb: Thumbnail?

    init(clip: Clip, missing: Bool, theme: Theme, box: CGSize, onMissing: @escaping (UUID) -> Void, look: CardLook? = nil) {
        self.clip = clip
        self.missing = missing
        self.theme = theme
        self.box = box
        self.onMissing = onMissing
        self.look = look
        // A thumbnail already decoded shows on the first frame (a recycled card, the drag preview).
        _thumb = State(initialValue: ThumbnailStore.shared.cached(clip.id))
    }

    var body: some View {
        ZStack {
            switch thumb {
            case .image(let img, let alpha) where alpha:
                Checkerboard(a: theme.checkA, b: theme.checkB)
                Image(decorative: img, scale: 1).resizable().interpolation(.high).scaledToFit()
                    .modifier(ThumbBlurIn(look: look))
            case .image(let img, _):
                theme.loadFill
                Image(decorative: img, scale: 1).resizable().interpolation(.high).scaledToFill()
                    .modifier(ThumbBlurIn(look: look))
            default:
                theme.loadFill
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !missing, let pw = clip.pixelWidth, let ph = clip.pixelHeight {
                Text(ClipText.dimensions(pw, ph))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(height: 13)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(4)
            }
        }
        .task(id: clip.id) {
            if let hit = ThumbnailStore.shared.cached(clip.id) {
                thumb = hit
            } else {
                let loaded = await ThumbnailStore.shared.load(clip, maxPixel: ThumbnailStore.maxPixel(for: clip, box: box))
                // Set before the picture first draws, so its first frame is already blurred and clear.
                if case .image = loaded { look?.thumbnailArrived() }
                thumb = loaded
            }
            if case .missing = thumb { onMissing(clip.id) }
        }
    }
}

/// The thumbnail's blur and fade while it is born. At rest no blur is applied at all, so the
/// picture stays pixel-crisp.
private struct ThumbBlurIn: ViewModifier {
    let look: CardLook?

    func body(content: Content) -> some View {
        let r = look?.thumbBlur ?? 0, o = look?.thumbOpacity ?? 1
        // The motion code's blur values are CSS pixels; the radius here is half that, as on the cards.
        if r > 0.05 {
            content.blur(radius: r / 2).opacity(o)
        } else {
            content.opacity(o)
        }
    }
}

/// The motion that lives inside a card's SwiftUI content: the copy and remove buttons' pop and
/// dip, and the thumbnail's blur-in. One per card cell, driven by `Anim`s like everything else;
/// the views read the published values, so only the part that moves is redrawn.
@MainActor @Observable
final class CardLook: MotionTarget {
    private(set) var copyScale = 1.0
    private(set) var removeScale = 1.0
    /// CSS pixels.
    private(set) var thumbBlur = 0.0
    private(set) var thumbOpacity = 1.0

    let copy: Anim
    let remove: Anim
    let ib: Anim
    let io: Anim
    /// Whether the card is on screen now, so a thumbnail that arrives is born blurred.
    @ObservationIgnored var isLive: () -> Bool = { false }

    init() {
        copy = Anim(1, owner: nil, eps: 0.0005)
        remove = Anim(1, owner: nil, eps: 0.0005)
        ib = Anim(0, owner: nil, eps: 0.05)
        io = Anim(1, owner: nil, eps: 0.002)
        for a in [copy, remove, ib, io] { a.owner = self }
    }

    func anim(_ b: CardButton) -> Anim { b == .copy ? copy : remove }
    func scale(_ b: CardButton) -> Double { b == .copy ? copyScale : removeScale }

    func render() {
        if copyScale != copy.v { copyScale = copy.v }
        if removeScale != remove.v { removeScale = remove.v }
        if thumbBlur != ib.v { thumbBlur = ib.v }
        if thumbOpacity != io.v { thumbOpacity = io.v }
    }

    /// A thumbnail finished loading. On screen it is born blurred: 12 → 0 px on `quick` and a fade
    /// on `fadeIn` over 140 ms; under Reduce Motion a 0.12 s fade. Off screen it simply shows.
    func thumbnailArrived() {
        guard isLive() else { return }
        if Motion.reduce {
            io.set(0)
            io.tween(to: 1, ms: 120)
        } else {
            ib.set(12)
            ib.spring(to: 0, duration: Motion.quick)
            io.set(0)
            io.tween(to: 1, ms: 140, ease: Motion.fadeIn)
        }
        render()
    }

    /// Back to rest, for a cell that is put away or reused.
    func rest() {
        copy.set(1)
        remove.set(1)
        ib.set(0)
        io.set(1)
        render()
    }
}

/// 8 pt squares of 12% and 6% grey behind transparent images.
struct Checkerboard: View {
    let a: Color
    let b: Color

    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            let cols = Int((size.width / s).rounded(.up)), rows = Int((size.height / s).rounded(.up))
            for r in 0..<rows {
                for c in 0..<cols {
                    let rect = CGRect(x: CGFloat(c) * s, y: CGFloat(r) * s, width: s, height: s)
                    ctx.fill(Path(rect), with: .color((r + c) % 2 == 0 ? b : a))
                }
            }
        }
    }
}

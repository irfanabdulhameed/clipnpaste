import SwiftUI
import ClipnpasteCore

/// One clip in the row. A pure picture of its clip and state: the panel controller does all input.
struct CardView: View {
    let clip: Clip
    let state: CardState
    let geometry: PanelGeometry
    let theme: Theme
    let now: Date
    var onMissing: (UUID) -> Void = { _ in }

    private var w: CGFloat { CGFloat(geometry.cardWidth) }
    private var h: CGFloat { CGFloat(geometry.cardHeight) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelGeometry.cardRadius, style: .continuous)
        let header = CGFloat(PanelGeometry.header), footer = CGFloat(PanelGeometry.footer)
        // Under Reduce Motion a press darkens instead of shrinking.
        let darkPress = state.pressed && theme.reduceMotion
        ZStack(alignment: .topLeading) {
            shape.fill(theme.cardFill)
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
                          box: CGSize(width: w - 12, height: h - header - 6), onMissing: onMissing)
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
        .overlay {
            if state.selected {
                let ring = theme.ringWidth
                RoundedRectangle(cornerRadius: 14 + ring, style: .continuous)
                    .strokeBorder(theme.accent, lineWidth: ring)
                    .padding(-(2 + ring))
            }
        }
        .scaleEffect(state.pressed && !theme.reduceMotion ? 0.97 : 1)
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
            if state.buttonsShown {
                HStack(spacing: 4) {
                    CardButtonView(
                        symbol: copySymbol, help: "Copy",
                        hovered: state.hoveredButton == .copy, pressed: state.pressedButton == .copy,
                        focused: state.focus == .copy, disabled: state.missing, theme: theme)
                    CardButtonView(
                        symbol: "xmark", help: "Remove",
                        hovered: state.hoveredButton == .remove, pressed: state.pressedButton == .remove,
                        focused: state.focus == .remove, disabled: false, theme: theme)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
    }

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

/// The 20 pt round copy and remove buttons.
struct CardButtonView: View {
    let symbol: String
    let help: String
    let hovered: Bool
    let pressed: Bool
    let focused: Bool
    let disabled: Bool
    let theme: Theme

    var body: some View {
        let fill = disabled ? theme.button : pressed ? theme.buttonPress : hovered ? theme.buttonHover : theme.button
        ZStack {
            Circle().fill(fill)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovered && !disabled ? theme.label : theme.label2)
                .contentTransition(.identity)
        }
        .frame(width: 20, height: 20)
        .background {
            if focused { Circle().strokeBorder(theme.accentRing, lineWidth: 3).frame(width: 26, height: 26) }
        }
        .scaleEffect(pressed && !theme.reduceMotion ? 0.92 : 1)
        .opacity(disabled ? 0.45 : 1)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An image card's thumbnail: a plain fill while it loads, then the picture.
struct ThumbView: View {
    let clip: Clip
    let missing: Bool
    let theme: Theme
    let box: CGSize
    let onMissing: (UUID) -> Void
    @State private var thumb: Thumbnail?

    var body: some View {
        ZStack {
            switch thumb {
            case .image(let img, let alpha) where alpha:
                Checkerboard(a: theme.checkA, b: theme.checkB)
                Image(decorative: img, scale: 1).resizable().interpolation(.high).scaledToFit()
            case .image(let img, _):
                theme.loadFill
                Image(decorative: img, scale: 1).resizable().interpolation(.high).scaledToFill()
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
                thumb = await ThumbnailStore.shared.load(clip, maxPixel: ThumbnailStore.maxPixel(for: clip, box: box))
            }
            if case .missing = thumb { onMissing(clip.id) }
        }
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

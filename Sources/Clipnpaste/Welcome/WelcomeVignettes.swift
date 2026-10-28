import AppKit
import SwiftUI
import ClipnpasteCore

/// Each step's moving picture: a loop of `period` seconds. Under Reduce Motion it stands still
/// on `still`, the frame that says the most. `shot` is a mid-motion frame for checks.
struct VignetteTiming {
    let period: Double
    let still: Double
    let shot: Double

    static func of(_ step: WelcomeStep) -> VignetteTiming {
        switch step {
        case .welcome: VignetteTiming(period: 4.8, still: 2.2, shot: 0.6)
        case .saved: VignetteTiming(period: 5.7, still: 3.6, shot: 0.92)
        case .shortcut, .tryIt: VignetteTiming(period: 4.6, still: 2.0, shot: 0.92)
        case .move: VignetteTiming(period: 4.8, still: 2.2, shot: 1.38)
        case .paste: VignetteTiming(period: 4.9, still: 0.5, shot: 1.02)
        case .copy: VignetteTiming(period: 4.4, still: 2.0, shot: 1.3)
        case .delete: VignetteTiming(period: 5.4, still: 0.65, shot: 0.86)
        case .reorder: VignetteTiming(period: 4.9, still: 1.3, shot: 1.15)
        case .dragOut: VignetteTiming(period: 5.0, still: 1.25, shot: 1.1)
        case .taller: VignetteTiming(period: 4.6, still: 2.3, shot: 1.45)
        case .history: VignetteTiming(period: 4.8, still: 2.0, shot: 0.72)
        case .settings: VignetteTiming(period: 4.6, still: 2.6, shot: 0.72)
        case .accessibility: VignetteTiming(period: 4.8, still: 2.0, shot: 1.32)
        case .chooseShortcut: VignetteTiming(period: 0, still: 0, shot: 0)
        }
    }
}

/// The stage: a soft well 480 × 220 with 16 pt corners that clips the picture.
struct WelcomeStageFrame<Content: View>: View {
    let theme: Theme
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(stageFill)
            content()
        }
        .frame(width: StageGeo.size.width, height: StageGeo.size.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.cardBorder ?? theme.cardHair, lineWidth: theme.cardBorder == nil ? 0.5 : 1))
    }

    private var stageFill: Color {
        if theme.reduceTransparency { return Color(nsColor: scheme == .dark ? Palette.gray(24) : Palette.gray(236)) }
        return Color(nsColor: Palette.ink(0.045, 0.07))
    }
}

/// The picture for one step at loop time `t`.
struct WelcomeVignette: View {
    let step: WelcomeStep
    let t: Double
    let c: StageContext

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch step {
            case .welcome: WelcomeV(t: t, c: c)
            case .saved: SavedV(t: t, c: c)
            case .shortcut, .tryIt: ShortcutV(t: t, c: c)
            case .move: MoveV(t: t, c: c)
            case .paste: PasteV(t: t, c: c)
            case .copy: CopyV(t: t, c: c)
            case .delete: DeleteV(t: t, c: c)
            case .reorder: ReorderV(t: t, c: c)
            case .dragOut: DragOutV(t: t, c: c)
            case .taller: TallerV(t: t, c: c)
            case .history: HistoryV(t: t, c: c)
            case .settings: SettingsV(t: t, c: c)
            case .accessibility: AccessibilityV(t: t, c: c)
            case .chooseShortcut: EmptyView()
            }
        }
        .frame(width: StageGeo.size.width, height: StageGeo.size.height, alignment: .topLeading)
    }
}

private func state(selected: Bool = false, hovered: Bool = false, hoveredButton: CardButton? = nil,
                   pressedButton: CardButton? = nil, mark: CopyMark? = nil) -> CardState {
    var s = CardState()
    s.selected = selected
    s.hovered = hovered
    s.hoveredButton = hoveredButton
    s.pressedButton = pressedButton
    s.mark = mark
    return s
}

/// The selection ring on its own, so it can slide between cards.
private struct Ring: View {
    let theme: Theme
    var body: some View {
        RoundedRectangle(cornerRadius: 16.5, style: .continuous)
            .strokeBorder(theme.accentRing, lineWidth: theme.ringWidth)
            .frame(width: StageGeo.cardW + 9, height: StageGeo.cardH + 9)
    }
}

/// The open's entrance for a card in reading order: 40 ms, then 12 ms apart.
private func entrance(_ t: Double, from start: Double, _ i: Int) -> CardFx {
    VT.born(t - start - 0.04 - 0.012 * Double(i))
}

// MARK: 1 Welcome: the panel rises, the cards come into focus.

private struct WelcomeV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let rise = 0.35
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 64, height: 64)
            .offset(x: 208, y: 30)
        MiniPanel(c: c, motion: VT.panel(t, rise: rise, leave: 3.9)) {
            ForEach(0..<5, id: \.self) { i in
                let o = StageGeo.card(Double(i))
                StageCard(clip: c.clip(i), c: c, state: state(selected: i == 0), ring: i == 0, fx: entrance(t, from: rise, i))
                    .offset(x: o.x, y: o.y)
            }
        }
    }
}

// MARK: 2 Saved: a line of text, then a photo, are copied and drop in as new cards.

private struct SavedV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let shift = VT.spring(t - 0.75) + VT.spring(t - 2.75) - 2 * VT.spring(t - 4.85)
        let photo = t >= 2.0
        MiniWindow(theme: c.theme, size: CGSize(width: 150, height: 92)) {
            if photo {
                StagePhoto(style: .bloom)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8))
            } else {
                Text(c.clip(WelcomeDemo.newText).plainText ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(c.theme.label)
                    .background(c.theme.accent.opacity(0.28))
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
        }
        .scaleEffect(VT.pop(t - 2.0, 1.04))
        .offset(x: 165, y: 16)
        Group {
            if t < 1.5 {
                KeyHUD(keys: ["⌘", "C"], t: t, born: 0.35, leave: 1.2, presses: [0.6], theme: c.theme)
            } else {
                KeyHUD(keys: ["⌘", "C"], t: t, born: 2.35, leave: 3.2, presses: [2.6], theme: c.theme)
            }
        }
        .offset(x: 330, y: 46)
        MiniPanel(c: c) {
            ForEach(0..<5, id: \.self) { i in
                let o = StageGeo.card(Double(i) + shift)
                StageCard(clip: c.clip(i), c: c, fx: CardFx()).offset(x: o.x, y: o.y)
            }
            if t >= 0.75, t < 4.9 {
                let o = StageGeo.card(VT.spring(t - 2.75))
                StageCard(clip: c.clip(WelcomeDemo.newText), c: c,
                          fx: VT.born(t - 0.75, lift: -24) + VT.gone(t - 4.7))
                    .offset(x: o.x, y: o.y)
            }
            if t >= 2.75, t < 4.9 {
                let o = StageGeo.card(0)
                StageCard(clip: c.clip(WelcomeDemo.newPhoto), c: c,
                          fx: VT.born(t - 2.75, lift: -24) + VT.gone(t - 4.7))
                    .offset(x: o.x, y: o.y)
            }
        }
    }
}

// MARK: 3 and 15 Shortcut: the keys go down one after another and the panel rises.

private struct ShortcutV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let rise = 0.75
        HStack(spacing: 8) {
            ForEach(Array(c.shortcutKeys.enumerated()), id: \.offset) { k, key in
                let down = 0.45 + 0.1 * Double(k)
                let release = 1.05 - down
                Keycap(label: key, large: true, pressed: t >= down && t < 1.05,
                       scale: VT.dip(t - down, release: release, depth: Motion.dipControl), theme: c.theme)
            }
        }
        .frame(width: StageGeo.size.width)
        .offset(y: 38)
        MiniPanel(c: c, motion: VT.panel(t, rise: rise, leave: 3.75)) {
            ForEach(0..<5, id: \.self) { i in
                let o = StageGeo.card(Double(i))
                StageCard(clip: c.clip(i), c: c, state: state(selected: i == 0), ring: i == 0, fx: entrance(t, from: rise, i))
                    .offset(x: o.x, y: o.y)
            }
        }
    }
}

// MARK: 4 Move: the ring slides card to card with →, glides back with ← held.

private struct MoveV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let steps: [(at: Double, d: Double)] = [(0.7, 1), (1.3, 1), (1.9, 1), (3.0, -1), (3.18, -1), (3.36, -1)]
        let ring = steps.reduce(0.0) { $0 + $1.d * VT.spring(t - $1.at) }
        let selected = Int(steps.filter { t >= $0.at }.reduce(0.0) { $0 + $1.d })
        let popAt = steps.last { t >= $0.at && $0.d > 0 }?.at
        Group {
            if t < 2.6 {
                KeyHUD(keys: ["→"], t: t, born: 0.45, leave: 2.4, presses: [0.7, 1.3, 1.9], theme: c.theme)
            } else {
                KeyHUD(keys: ["←"], t: t, born: 2.75, leave: 3.95, presses: [3.0], hold: 0.55, theme: c.theme)
            }
        }
        .frame(width: StageGeo.size.width)
        .offset(y: 50)
        MiniPanel(c: c) {
            ForEach(0..<5, id: \.self) { i in
                let o = StageGeo.card(Double(i))
                let pop = (i == selected && popAt != nil && selected > 0) ? VT.pop(t - (popAt ?? 0)) : 1
                StageCard(clip: c.clip(i), c: c, state: state(selected: i == selected), fx: CardFx(scale: pop))
                    .offset(x: o.x, y: o.y)
            }
            let r = StageGeo.card(ring)
            Ring(theme: c.theme).offset(x: r.x - 4.5, y: r.y - 4.5)
        }
    }
}

// MARK: 5 Paste: Return, and the card flies up into a text field; the panel leaves.

private struct PasteV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let field = CGRect(x: 120, y: 30, width: 240, height: 30)
        let pasted = t >= 1.15 && t < 3.6
        let caretOn = Int(t * 2) % 2 == 0
        let fieldShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 1) {
            if pasted {
                Text(c.clip(1).plainText ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(c.theme.label)
                    .lineLimit(1)
                    .fx(VT.born(t - 1.15, blur: 10, scale: 1, lift: 0) + VT.gone(t - 3.3, ms: 160, blur: 8, scale: 1))
            }
            Rectangle().fill(c.theme.label).frame(width: 1.5, height: 14).opacity(caretOn ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: field.width, height: field.height)
        .background(fieldShape.fill(c.theme.cardFill))
        .overlay(fieldShape.strokeBorder(c.theme.cardBorder ?? Color(nsColor: Palette.ink(0.14, 0.18)), lineWidth: c.theme.cardBorder == nil ? 0.5 : 1))
        .offset(x: field.minX, y: field.minY)
        KeyHUD(keys: ["↩"], t: t, born: 0.55, leave: 1.4, presses: [0.8], theme: c.theme)
            .offset(x: 372, y: 33)
        let panel = t < 3.6 ? VT.panel(t, rise: nil, leave: 0.95) : VT.panel(t, rise: 3.6, leave: nil)
        let away = t >= 0.9 && t < 3.6
        MiniPanel(c: c, motion: panel) {
            ForEach(0..<5, id: \.self) { i in
                if !(i == 1 && away) {
                    let o = StageGeo.card(Double(i))
                    let fx = t >= 3.6 ? entrance(t, from: 3.6, i)
                        : CardFx(scale: i == 1 ? VT.dip(t - 0.8, release: 0.1, depth: Motion.dipCard) : 1)
                    StageCard(clip: c.clip(i), c: c, state: state(selected: i == 1), ring: i == 1, fx: fx)
                        .offset(x: o.x, y: o.y)
                }
            }
        }
        if t >= 0.9, t < 1.4 {
            let k = VT.spring(t - 0.9)
            let from = StageGeo.cardCentre(1)
            let to = CGPoint(x: field.midX, y: field.midY)
            let p = CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k)
            let fade = k < 0.6 ? 1 : max(0, 1 - (k - 0.6) / 0.35)
            StageCard(clip: c.clip(1), c: c, state: state(selected: true),
                      fx: CardFx(blur: 6 * sin(.pi * k), opacity: fade, scale: StageGeo.s * (1 - 0.65 * k)))
                .frame(width: StageGeo.cardW, height: StageGeo.cardH)
                .position(p)
        }
    }
}

// MARK: 6 Copy: the pointer clicks the copy button; it turns into a checkmark.

private struct CopyV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let card = CGPoint(x: 158, y: 55)
        let button = StageGeo.copyButton(in: card)
        let over = t >= 0.62 && t < 3.32
        let pressed = t >= 1.25 && t < 1.38
        let marked = t >= 1.38 && t < 3.0
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(nsColor: Palette.pair(NSColor(white: 1, alpha: 0.66), NSColor(white: 0.19, alpha: 0.86))))
            .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
            .frame(width: 560, height: 150)
            .offset(x: -40, y: card.y - 28)
        StageCard(clip: c.clip(3), c: c).offset(x: card.x - StageGeo.pitch, y: card.y)
        StageCard(clip: c.clip(2), c: c).offset(x: card.x + StageGeo.pitch, y: card.y)
        StageCard(clip: c.clip(0), c: c,
                  state: state(selected: true, hovered: t >= 0.55 && t < 3.32,
                               hoveredButton: over ? .copy : nil, pressedButton: pressed ? .copy : nil,
                               mark: marked ? .done : nil),
                  look: c.look, ring: true)
            .offset(x: card.x, y: card.y)
            .onChange(of: t, initial: true) {
                let s = t < 1.25 ? VT.pop(t - 0.62) : VT.dip(t - 1.25, release: 0.13, depth: Motion.dipControl)
                c.look.copy.set(Motion.reduce ? 1 : s)
                c.look.remove.set(1)
                c.look.render()
            }
        StagePointer(at: VT.path(t, CGPoint(x: 440, y: 236), [
            .init(at: 0.2, to: CGPoint(x: button.x + 1, y: button.y + 2), duration: 0.5),
            .init(at: 3.3, to: CGPoint(x: 470, y: 250), duration: 0.3, leaving: true),
        ]))
    }
}

// MARK: 7 Delete: ⌘⌫ removes the selected card, then the remove button does; the gap closes.

private struct DeleteV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        KeyHUD(keys: ["⌘", "⌫"], t: t, born: 0.4, leave: 1.3, presses: [0.7], theme: c.theme)
            .frame(width: StageGeo.size.width)
            .offset(y: 50)
        let reborn = t >= 4.55
        let selected = t < 0.85 ? 1 : (t < 2.8 ? 2 : 3)
        let over = t >= 2.25 && t < 3.1
        MiniPanel(c: c) {
            ForEach(0..<7, id: \.self) { i in
                if reborn {
                    if i < 5 {
                        let o = StageGeo.card(Double(i))
                        StageCard(clip: c.clip(i), c: c, state: state(selected: i == 1), ring: i == 1,
                                  fx: entrance(t, from: 4.5, i))
                            .offset(x: o.x, y: o.y)
                    }
                } else {
                    let slot = Double(i) - (i >= 2 ? VT.spring(t - 0.85) : 0) - (i >= 3 ? VT.spring(t - 2.8) : 0)
                    let leaving = i == 1 ? VT.gone(t - 0.75) : (i == 2 ? VT.gone(t - 2.72) : CardFx())
                    let o = StageGeo.card(slot)
                    StageCard(clip: c.clip(i), c: c,
                              state: state(selected: i == selected, hovered: i == 2 && over,
                                           hoveredButton: i == 2 && over ? .remove : nil,
                                           pressedButton: i == 2 && t >= 2.6 && t < 2.72 ? .remove : nil),
                              look: i == 2 ? c.look : nil, fx: leaving + VT.gone(t - 4.3, ms: 160))
                        .offset(x: o.x, y: o.y)
                }
            }
            if !reborn {
                let r = StageGeo.card(1)
                Ring(theme: c.theme).offset(x: r.x - 4.5, y: r.y - 4.5).fx(VT.gone(t - 4.3, ms: 160))
            }
        }
        .onChange(of: t, initial: true) {
            let s = t < 2.6 ? VT.pop(t - 2.25) : VT.dip(t - 2.6, release: 0.12, depth: Motion.dipControl)
            c.look.remove.set(Motion.reduce ? 1 : s)
            c.look.copy.set(1)
            c.look.render()
        }
        let button = StageGeo.onStage(StageGeo.removeButton(in: StageGeo.card(1)))
        StagePointer(at: VT.path(t, CGPoint(x: 330, y: 240), [
            .init(at: 1.75, to: CGPoint(x: button.x + 1, y: button.y + 1), duration: 0.5),
            .init(at: 3.1, to: CGPoint(x: 340, y: 250), duration: 0.3, leaving: true),
        ]))
    }
}

// MARK: 8 Reorder: a card is dragged sideways; the others part, then it goes back.

private struct ReorderV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let dragSlot = 1 + 2 * VT.spring(t - 0.75, 1.0) - 2 * VT.spring(t - 2.9, 1.0)
        let lifted = (t >= 0.75 && t < 1.9) || (t >= 2.9 && t < 4.05)
        let liftK = lifted ? VT.spring(t - (t < 2.9 ? 0.75 : 2.9), Motion.quick)
                           : 1 - VT.spring(t - (t < 2.9 ? 1.9 : 4.05), Motion.quick)
        let press = t < 2.9 ? VT.dip(t - 0.6, release: 0.15, depth: Motion.dipCard) : VT.dip(t - 2.75, release: 0.15, depth: Motion.dipCard)
        let slots: [Int: Double] = [
            0: 0,
            2: 2 - VT.spring(t - 0.95) + VT.spring(t - 3.45),
            3: 3 - VT.spring(t - 1.2) + VT.spring(t - 3.2),
            4: 4,
        ]
        MiniPanel(c: c) {
            ForEach([0, 2, 3, 4], id: \.self) { i in
                let o = StageGeo.card(slots[i] ?? 0)
                StageCard(clip: c.clip(i), c: c).offset(x: o.x, y: o.y)
            }
            let o = StageGeo.card(dragSlot)
            StageCard(clip: c.clip(1), c: c, state: state(hovered: t >= 0.5 && t < 4.3), preview: lifted || liftK > 0.05,
                      fx: CardFx(scale: press * (1 + 0.03 * max(0, liftK))))
                .shadow(color: .black.opacity(0.18 * max(0, liftK)), radius: 10, y: 4)
                .offset(x: o.x, y: o.y)
        }
        let grip = StageGeo.cardCentre(dragSlot)
        let start = CGPoint(x: 300, y: 236)
        let arrive = VT.spring(t - 0.15, 0.4)
        let leave = VT.tween(t - 4.3, 300, Motion.leave)
        let p = CGPoint(x: start.x + (grip.x - start.x) * arrive + (330 - grip.x) * leave,
                        y: start.y + (grip.y - start.y) * arrive + (250 - grip.y) * leave)
        StagePointer(at: p)
    }
}

// MARK: 9 Drag out: the card tilts −6° on its way to a window; the panel shrinks to a strip.

private struct DragOutV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let win = CGRect(x: 24, y: 12, width: 196, height: 112)
        MiniWindow(theme: c.theme, size: win.size) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Weekend").font(.system(size: 10, weight: .semibold)).foregroundStyle(c.theme.label)
                Text("Train at 8:12 from platform 3.").font(.system(size: 9)).foregroundStyle(c.theme.label2)
                if t >= 1.7 {
                    Text(c.clip(3).plainText ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(c.theme.label2)
                        .fx(VT.born(t - 1.7, blur: 10, scale: 1, lift: 0) + VT.gone(t - 4.2, ms: 160, blur: 8, scale: 1))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
        }
        .offset(x: win.minX, y: win.minY)
        let strip = VT.spring(t - 0.75) - VT.spring(t - 1.9)
        let h = 150 - (150 - StageGeo.stripH) * strip
        MiniPanel(c: c, height: h, chrome: 1 - strip) {
            ForEach(0..<5, id: \.self) { i in
                if !(i == 3 && t >= 0.6 && t < 1.95) {
                    let o = StageGeo.card(Double(i))
                    let fx = t < 1.95 ? VT.gone(t - 0.75, ms: 160, blur: 12, scale: 1) : entrance(t, from: 1.9, i)
                    StageCard(clip: c.clip(i), c: c, state: state(selected: i == 0), ring: i == 0,
                              fx: fx + CardFx(scale: i == 3 ? VT.dip(t - 0.5, release: 0.1, depth: Motion.dipCard) : 1))
                        .offset(x: o.x, y: o.y)
                }
            }
        }
        let from = StageGeo.cardCentre(3)
        let to = CGPoint(x: win.midX, y: win.midY + 8)
        let k = VT.spring(t - 0.6, 0.9)
        let card = CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k)
        if t >= 0.6, t < 1.9 {
            let tilt = t < 1.6 ? -6 * VT.spring(t - 0.6, 0.25) : -6 * (1 - VT.spring(t - 1.6, Motion.quick))
            StageCard(clip: c.clip(3), c: c, preview: true,
                      fx: CardFx(scale: StageGeo.s * 1.04, rotation: tilt) + VT.gone(t - 1.6, ms: 200, blur: 6, scale: 0.6))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .frame(width: StageGeo.cardW, height: StageGeo.cardH)
                .position(card)
        }
        let dropK = VT.spring(1.0, 0.9)
        let drop = CGPoint(x: from.x + (to.x - from.x) * dropK, y: from.y + (to.y - from.y) * dropK)
        let away = VT.tween(t - 2.0, 350, Motion.leave)
        let hand: CGPoint = t < 0.6 ? VT.path(t, CGPoint(x: 420, y: 236), [.init(at: 0.1, to: from, duration: 0.4)])
            : (t < 1.6 ? card : CGPoint(x: drop.x + 160 * away, y: drop.y + 150 * away))
        StagePointer(at: hand)
    }
}

// MARK: 10 Taller: the pill is dragged up; the panel grows to two, then three rows.

private struct TallerV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let rows = 1 + VT.spring(t - 1.25) + VT.spring(t - 1.85) - VT.spring(t - 2.8) - VT.spring(t - 3.1)
        let h = StageGeo.panelH(rows: rows)
        let pressed = t >= 0.95 && t < 3.4
        let hover = t >= 0.6 && t < 3.7
        let scale = t < 0.95 ? VT.pop(t - 0.6) : VT.dip(t - 0.95, release: 2.45, depth: Motion.dipPill)
        MiniPanel(c: c, height: h, pill: pressed ? .pressed : (hover ? .hover : .rest), pillScale: scale) {
            ForEach(0..<15, id: \.self) { i in
                let row = i / 5, col = i % 5
                let o = StageGeo.card(Double(col), row: Double(row))
                let fx: CardFx = switch row {
                case 1: VT.born(t - 1.3 - 0.012 * Double(col)) + VT.gone(t - 3.1, ms: 160)
                case 2: VT.born(t - 1.9 - 0.012 * Double(col)) + VT.gone(t - 2.8, ms: 160)
                default: CardFx()
                }
                StageCard(clip: c.clip(i), c: c, state: state(selected: i == 0), ring: i == 0, fx: fx)
                    .offset(x: o.x, y: o.y)
            }
        }
        let pill = StageGeo.onStage(CGPoint(x: StageGeo.panelW / 2, y: 12), panelH: h)
        let start = CGPoint(x: 330, y: 236)
        let a = VT.spring(t - 0.2, 0.4)
        let l = VT.tween(t - 3.7, 300, Motion.leave)
        StagePointer(at: CGPoint(x: start.x + (pill.x + 2 - start.x) * a + 90 * l,
                                 y: start.y + (pill.y + 2 - start.y) * a + 120 * l))
    }
}

// MARK: 11 History: ⌘Y opens history, clips grouped under days.

private struct HistoryV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let open = VT.spring(t - 0.6) - VT.spring(t - 3.5)
        let on = t >= 0.6 && t < 3.5
        let h = 150 + 244 * open
        MiniPanel(c: c, height: h, pillHidden: on, historyOn: on,
                  historyScale: VT.pop(t - 0.6) * VT.pop(t - 3.5)) {
            ForEach(0..<5, id: \.self) { i in
                let o = StageGeo.card(Double(i))
                let fx = t < 3.5 ? VT.gone(t - 0.6, ms: 160) : entrance(t, from: 3.5, i)
                StageCard(clip: c.clip(i), c: c, state: state(selected: i == 0), ring: i == 0, fx: fx)
                    .offset(x: o.x, y: o.y)
            }
            if t >= 0.6, t < 3.75 {
                let leave = VT.gone(t - 3.5, ms: 160)
                ForEach(Array(WelcomeDemo.dayLabels(c).enumerated()), id: \.offset) { g, day in
                    Text(day)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(c.theme.label2)
                        .offset(x: 18, y: 34 + 148 * CGFloat(g))
                        .fx(VT.born(t - 0.66 - 0.05 * Double(g), blur: 12, scale: 1, lift: 8) + leave)
                    ForEach(0..<5, id: \.self) { col in
                        let i = g * 5 + col
                        StageCard(clip: c.clip(i), c: c, state: state(selected: i == 0), ring: i == 0,
                                  fx: VT.born(t - 0.68 - 0.05 * Double(g) - 0.012 * Double(col)) + leave)
                            .offset(x: StageGeo.side + StageGeo.pitch * CGFloat(col), y: 56 + 148 * CGFloat(g))
                    }
                }
            }
        }
        KeyHUD(keys: ["⌘", "Y"], t: t, born: t < 2 ? 0.3 : 3.2, leave: t < 2 ? 1.0 : 3.9,
               presses: [t < 2 ? 0.55 : 3.45], theme: c.theme)
            .offset(x: 18, y: 16)
    }
}

// MARK: 12 Settings: ⌘, opens Settings; auto-clear is set.

private struct SettingsV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let win = CGRect(x: 80, y: 22, width: 320, height: 176)
        let popup = CGPoint(x: 352, y: 130)
        KeyHUD(keys: ["⌘", ","], t: t, born: 0.15, leave: 0.85, presses: [0.4], theme: c.theme)
            .frame(width: StageGeo.size.width)
            .offset(y: 96)
        MiniWindow(theme: c.theme, size: win.size) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases) { s in
                        HStack(spacing: 5) {
                            Image(systemName: s.symbol).font(.system(size: 8)).frame(width: 11)
                            Text(s.title).font(.system(size: 9))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(s == .privacy ? Color.white : c.theme.label)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(s == .privacy ? c.theme.accent : .clear))
                    }
                }
                .padding(6)
                .frame(width: 96, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: Palette.ink(0.035, 0.05)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Privacy").font(.system(size: 11, weight: .semibold)).foregroundStyle(c.theme.label)
                        .padding(.bottom, 8)
                    VStack(spacing: 0) {
                        row("Keep up to", "5,000 clips")
                        Divider().opacity(0.5)
                        row("Image storage", "2 GB")
                        Divider().opacity(0.5)
                        row("Auto-clear clips older than", nil, popup: true)
                    }
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: Palette.ink(0.03, 0.05))))
                }
                .padding(10)
            }
        }
        .fx(VT.born(t - 0.55, blur: 16, scale: 1.04, lift: 8) + VT.gone(t - 3.8, ms: 200, blur: 12, scale: 0.96))
        .offset(x: win.minX, y: win.minY - 4)
        StagePointer(at: VT.path(t, CGPoint(x: 420, y: 236), [
            .init(at: 1.0, to: CGPoint(x: popup.x + 10, y: popup.y + 3), duration: 0.5),
            .init(at: 2.6, to: CGPoint(x: 460, y: 250), duration: 0.3, leaving: true),
        ]))
    }

    private func row(_ label: String, _ value: String?, popup: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 9)).foregroundStyle(c.theme.label)
            Spacer(minLength: 4)
            if let value { Text(value).font(.system(size: 9)).foregroundStyle(c.theme.label2) }
            if popup {
                // A hard cut from Never to 30 days, with a pop; pressed flips darker and dips.
                let pressed = t >= 1.75 && t < 1.9
                HStack(spacing: 3) {
                    Text(t >= 1.9 ? "30 days" : "Never").font(.system(size: 9))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 6, weight: .semibold))
                }
                .foregroundStyle(c.theme.label)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(pressed ? c.theme.buttonPress : c.theme.button))
                .scaleEffect(pressed ? VT.dip(t - 1.75, release: 0.15, depth: Motion.dipControl) : VT.pop(t - 1.9, 1.06))
            }
        }
        .frame(height: 24)
    }
}

// MARK: 13 Accessibility: Clipnpaste is switched on in System Settings.

private struct AccessibilityV: View {
    let t: Double
    let c: StageContext

    var body: some View {
        let win = CGRect(x: 90, y: 34, width: 300, height: 138)
        let on = t >= 1.3
        let sw = CGPoint(x: win.minX + 263, y: win.minY + 81)
        let fx = VT.born(t - 0.05, blur: 16, scale: 1.04, lift: 8) + VT.gone(t - 3.9, ms: 200, blur: 12, scale: 0.96)
        MiniWindow(theme: c.theme, size: win.size) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility").font(.system(size: 12, weight: .semibold)).foregroundStyle(c.theme.label)
                Text("Allow the apps below to control your computer.")
                    .font(.system(size: 9)).foregroundStyle(c.theme.label2)
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 22, height: 22)
                    Text("Clipnpaste").font(.system(size: 11)).foregroundStyle(c.theme.label)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: Palette.ink(0.035, 0.06))))
                .padding(.top, 8)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
        .fx(fx)
        .offset(x: win.minX, y: win.minY)
        // The switch: a one-frame flip, knob and colour together, with a pop.
        let press = VT.dip(t - 1.15, release: 0.15, depth: Motion.dipControl)
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Color(nsColor: .systemGreen) : Color(nsColor: Palette.ink(0.14, 0.22)))
            Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5).padding(2)
        }
        .frame(width: 30, height: 18)
        .scaleEffect(press * VT.pop(t - 1.3))
        .fx(fx)
        .position(sw)
        StagePointer(at: VT.path(t, CGPoint(x: 420, y: 236), [
            .init(at: 0.35, to: CGPoint(x: sw.x + 3, y: sw.y + 2), duration: 0.5),
            .init(at: 2.2, to: CGPoint(x: 450, y: 250), duration: 0.3, leaving: true),
        ]))
    }
}

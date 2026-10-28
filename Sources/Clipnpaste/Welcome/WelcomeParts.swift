import AppKit
import SwiftUI
import ClipnpasteCore

// The pieces the tour's moving pictures are made of: timing curves from the app's motion tokens,
// miniature panels and cards (the real CardView, drawn at half size), keycaps and the pointer.

/// Timing for the vignettes. Each picture is a pure function of its loop time `t`, built from the
/// app's own curves: springs with bounce 0 (never past rest), exits on `leave` (they accelerate
/// away), house easing on fades, the 1.08 pop and the press dips.
enum VT {
    /// Share of a spring's travel `dt` seconds after it starts.
    static func spring(_ dt: Double, _ duration: Double = Motion.arrive) -> Double {
        dt <= 0 ? 0 : Spring.progress(duration: duration, at: dt)
    }

    static func tween(_ dt: Double, _ ms: Double, _ ease: CubicBezier = Motion.linear) -> Double {
        dt <= 0 ? 0 : ease(min(dt * 1000 / ms, 1))
    }

    /// 1 → peak → 1: 60 ms up on popUp, 140 ms back on popDown.
    static func pop(_ dt: Double, _ peak: Double = Motion.popPeak) -> Double {
        guard dt > 0, dt < 0.2 else { return 1 }
        if dt < 0.06 { return 1 + (peak - 1) * Motion.popUp(dt / 0.06) }
        return peak - (peak - 1) * Motion.popDown((dt - 0.06) / 0.14)
    }

    /// A press: dips to `depth` over 70 ms and holds until `release`, then springs back.
    static func dip(_ dt: Double, release: Double, depth: Double) -> Double {
        guard dt > 0 else { return 1 }
        if dt < release { return 1 - (1 - depth) * tween(dt, Motion.dipMs, Motion.popUp) }
        return depth + (1 - depth) * spring(dt - release, Motion.quick)
    }

    /// Born blurred: the open's focus curve for blur and scale, the fade ahead of it, a short lift.
    static func born(_ dt: Double, blur: Double = 20, scale: Double = 1.06, lift: Double = 16) -> CardFx {
        guard dt > 0 else { return CardFx(blur: blur, opacity: 0, scale: scale, dy: lift) }
        let f = Motion.focus(min(dt * 1000 / Motion.focusMs, 1))
        let o = Motion.materialise(min(dt * 1000 / Motion.focusFadeMs, 1))
        return CardFx(blur: blur * (1 - f), opacity: o, scale: scale + (1 - scale) * f, dy: lift * (1 - spring(dt)))
    }

    /// Leaving: blur up, fade and shrink on `leave`, accelerating away.
    static func gone(_ dt: Double, ms: Double = 180, blur: Double = 16, scale: Double = 0.94) -> CardFx {
        guard dt > 0 else { return CardFx() }
        let p = tween(dt, ms, Motion.leave)
        return CardFx(blur: blur * p, opacity: 1 - p, scale: 1 + (scale - 1) * p)
    }

    /// The panel's rise (spring, materialising) and its exit (dropping away on `leave`), in stage points.
    static func panel(_ t: Double, rise: Double?, leave: Double?, travel: Double = 95) -> PanelFx {
        var s = PanelFx()
        if let rise {
            let dt = t - rise
            if dt <= 0 { return PanelFx(y: travel, opacity: 0, scale: Motion.materialiseScale) }
            let m = tween(dt, Motion.materialiseMs, Motion.materialise)
            s = PanelFx(y: travel * (1 - spring(dt)), opacity: m, scale: Motion.materialiseScale + (1 - Motion.materialiseScale) * m)
        }
        if let leave, t > leave {
            let p = tween(t - leave, 220, Motion.leave)
            s.y += travel * p
            s.opacity *= 1 - p
        }
        return s
    }

    /// A point that moves from `start` through each stop: a spring per move (or `leave` for an
    /// exit), so a move that starts before the last ends keeps its speed.
    static func path(_ t: Double, _ start: CGPoint, _ moves: [Move]) -> CGPoint {
        var p = start, from = start
        for m in moves {
            let k = m.leaving ? tween(t - m.at, m.duration * 1000, Motion.leave) : spring(t - m.at, m.duration)
            p.x += (m.to.x - from.x) * k
            p.y += (m.to.y - from.y) * k
            from = m.to
        }
        return p
    }

    struct Move {
        let at: Double
        let to: CGPoint
        var duration: Double = 0.45
        var leaving = false
    }
}

/// How a card (or any piece) is drawn at one moment: blur in CSS points, as the app's motion code
/// uses (the view's radius is half), opacity, scale about its centre, a tilt and an offset.
struct CardFx {
    var blur = 0.0
    var opacity = 1.0
    var scale = 1.0
    var rotation = 0.0
    var dx = 0.0
    var dy = 0.0

    static func + (a: CardFx, b: CardFx) -> CardFx {
        CardFx(blur: a.blur + b.blur, opacity: a.opacity * b.opacity, scale: a.scale * b.scale,
               rotation: a.rotation + b.rotation, dx: a.dx + b.dx, dy: a.dy + b.dy)
    }
}

struct PanelFx {
    var y = 0.0
    var opacity = 1.0
    var scale = 1.0
}

extension View {
    /// Applies a CardFx. No blur filter at all when sharp, so rest frames stay crisp.
    @ViewBuilder func fx(_ f: CardFx) -> some View {
        let v = self.scaleEffect(f.scale).rotationEffect(.degrees(f.rotation))
        if f.blur > 0.05 {
            v.blur(radius: f.blur / 2).opacity(f.opacity).offset(x: f.dx, y: f.dy)
        } else {
            v.opacity(f.opacity).offset(x: f.dx, y: f.dy)
        }
    }
}

// MARK: Geometry

/// The stage is 480 × 220. The miniature panel is the real panel drawn at half size: real points
/// inside it (cards 164 × 110, 12 pt apart, a 28 pt top bar), stage points outside.
enum StageGeo {
    static let size = CGSize(width: 480, height: 220)
    static let s: CGFloat = 0.5
    static let cardW: CGFloat = 164, cardH: CGFloat = 110
    static let pitch: CGFloat = 176, rowPitch: CGFloat = 122
    static let side: CGFloat = 16, top: CGFloat = 28
    static let panelW: CGFloat = 900
    static let panelX: CGFloat = 15
    static let panelBottom: CGFloat = 210
    static let stripH: CGFloat = CGFloat(PanelGrid.stripHeight)

    /// Real height of a panel showing `rows` rows (fractions while it grows).
    static func panelH(rows: Double) -> CGFloat { 150 + rowPitch * CGFloat(rows - 1) }

    /// Top-left of a card in the panel, real points.
    static func card(_ slot: Double, row: Double = 0) -> CGPoint {
        CGPoint(x: side + pitch * CGFloat(slot), y: top + rowPitch * CGFloat(row))
    }

    /// A panel point (real) on the stage, for a panel `h` tall (real) moved down by `drop` (stage).
    static func onStage(_ p: CGPoint, panelH h: CGFloat = 150, drop: CGFloat = 0) -> CGPoint {
        CGPoint(x: panelX + p.x * s, y: panelBottom - h * s + drop + p.y * s)
    }

    /// The centre of a card slot on the stage.
    static func cardCentre(_ slot: Double, row: Double = 0, panelH h: CGFloat = 150) -> CGPoint {
        let o = card(slot, row: row)
        return onStage(CGPoint(x: o.x + cardW / 2, y: o.y + cardH / 2), panelH: h)
    }

    /// The real card buttons, from CardView's header: trailing padding 6, 28 pt buttons 4 apart,
    /// centred in the 34 pt header.
    static let buttonSize: CGFloat = 28
    static func copyButton(in card: CGPoint) -> CGPoint {
        CGPoint(x: card.x + cardW - 6 - buttonSize - 4 - buttonSize / 2, y: card.y + 17)
    }
    static func removeButton(in card: CGPoint) -> CGPoint {
        CGPoint(x: card.x + cardW - 6 - buttonSize / 2, y: card.y + 17)
    }
}

// MARK: Context

/// What every picture draws with: the theme, the demo clips, and the current shortcut's keys.
@MainActor
struct StageContext {
    let theme: Theme
    let now: Date
    let clips: [Clip]
    let photos: [UUID: StagePhoto.Style]
    let shortcutKeys: [String]
    let geometry: PanelGeometry
    /// The button motion of the one card a picture presses (pop and dip), set each frame.
    let look: CardLook

    func photo(_ id: UUID) -> StagePhoto.Style? { photos[id] }
    func clip(_ i: Int) -> Clip { clips[i % clips.count] }
}

/// Believable demo clips: what people copy in a week. Nothing here is read from the real history.
@MainActor
enum WelcomeDemo {
    static let geometry = PanelGeometry(visibleWidth: 1440, visibleHeight: 875, screenHeight: 900)

    /// Text (empty for a photo), source app, and when: today `minutes` ago, or on an earlier
    /// day (`day` 1 or 2) at `minutes` past midnight.
    private static let texts: [(String, String, Int, Double)] = [
        ("Dinner at Lina's on Friday, 7:30. I'll bring the lemon tart.", "com.apple.Notes", 0, 2),
        ("https://maps.apple.com/?q=Corner+Cafe", "com.apple.Safari", 0, 9),
        ("Hi Sam, the October invoice is attached. Let me know if anything looks off.", "com.apple.mail", 0, 26),
        ("On my way, ten minutes", "com.apple.MobileSMS", 0, 58),
        ("git switch -c onboarding", "com.apple.Terminal", 0, 120),
        ("", "com.apple.Photos", 1, 1130),
        ("Flight TP 1351, seat 14A. Gate closes at 09:40.", "com.apple.Notes", 1, 1050),
        ("Opening hours: Monday to Saturday, 9:00 to 18:00", "com.apple.Safari", 1, 980),
        ("", "com.apple.Preview", 1, 900),
        ("Thanks! I've added the notes to the shared folder.", "com.apple.mail", 1, 610),
        ("Can you grab milk on the way home?", "com.apple.MobileSMS", 2, 1100),
        ("swift build -c release", "com.apple.Terminal", 2, 1020),
        ("", "com.apple.Photos", 2, 940),
        ("Groceries: oats, lemons, coffee, rice", "com.apple.Notes", 2, 700),
        ("Return window: 30 days from delivery", "com.apple.Safari", 2, 560),
        // The two new copies of the "saved" step.
        ("Meet at the north entrance at 10.", "com.apple.Notes", 0, 0),
        ("", "com.apple.Photos", 0, 0),
    ]
    private static let photoStyles: [Int: StagePhoto.Style] = [5: .sunset, 8: .lake, 12: .dunes, 16: .bloom]

    static func context(theme: Theme, shortcutKeys: [String], look: CardLook, now: Date = Date()) -> StageContext {
        var clips: [Clip] = []
        var photos: [UUID: StagePhoto.Style] = [:]
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        for (i, (text, app, day, minutes)) in texts.enumerated() {
            let date = day == 0
                ? max(now.addingTimeInterval(-minutes * 60 - 20), today)
                : (cal.date(byAdding: .day, value: -day, to: today) ?? today).addingTimeInterval(minutes * 60)
            if let style = photoStyles[i] {
                let c = Clip(kind: .image, pixelWidth: style.pixels.0, pixelHeight: style.pixels.1, sourceBundleID: app,
                             createdAt: date, contentHash: "welcome-\(i)")
                photos[c.id] = style
                clips.append(c)
            } else {
                clips.append(Clip(kind: .text, plainText: text, sourceBundleID: app, createdAt: date, contentHash: "welcome-\(i)"))
            }
        }
        return StageContext(theme: theme, now: now, clips: clips, photos: photos, shortcutKeys: shortcutKeys,
                            geometry: geometry, look: look)
    }

    /// The history's day headers for the three groups of five.
    static func dayLabels(_ c: StageContext) -> [String] {
        [0, 5, 10].map { DayLabel.text(for: c.clip($0).createdAt, now: c.now) }
    }

    /// The first fifteen, the history.
    static let historyCount = 15
    static let newText = 15
    static let newPhoto = 16
}

// MARK: Panel and cards

/// The real panel, miniature: glass, the 28 pt top bar with the resize pill and History, and the
/// cards in real points, clipped to its 24 pt corners. Placed on the stage at half size.
struct MiniPanel<Content: View>: View {
    let c: StageContext
    var height: CGFloat = 150
    var motion = PanelFx()
    var pill: PillState = .rest
    var pillScale = 1.0
    var pillHidden = false
    var historyOn = false
    var historyScale = 1.0
    /// The History button fades while the panel is a strip (the pill stays).
    var chrome = 1.0
    @ViewBuilder var content: () -> Content

    enum PillState { case rest, hover, pressed }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let theme = c.theme
        ZStack(alignment: .topLeading) {
            shape.fill(glassFill)
            content()
                .frame(width: StageGeo.panelW, height: height, alignment: .topLeading)
                .clipShape(shape)
            shape.strokeBorder(Color(nsColor: Palette.edge), lineWidth: 1)
            if !pillHidden {
                Capsule().fill(pillColor)
                    .frame(width: 36, height: 5)
                    .scaleEffect(pillScale)
                    .offset(x: StageGeo.panelW / 2 - 18, y: 9.5)
            }
            ZStack {
                Circle().fill(historyOn ? theme.accent : .clear)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(historyOn ? Color.white : theme.label2)
            }
            .frame(width: 22, height: 22)
            .scaleEffect(historyScale)
            .opacity(chrome)
            .offset(x: StageGeo.panelW - 34, y: 3)
        }
        .frame(width: StageGeo.panelW, height: height, alignment: .topLeading)
        .scaleEffect(StageGeo.s, anchor: .topLeading)
        .frame(width: StageGeo.panelW * StageGeo.s, height: height * StageGeo.s, alignment: .topLeading)
        .scaleEffect(motion.scale)
        .shadow(color: .black.opacity(scheme == .dark ? 0.40 : 0.14), radius: 7, y: 3)
        .opacity(motion.opacity)
        .offset(x: StageGeo.panelX, y: StageGeo.panelBottom - height * StageGeo.s + motion.y)
    }

    private var glassFill: Color {
        if c.theme.reduceTransparency { return Color(nsColor: .windowBackgroundColor) }
        return scheme == .dark ? Color(white: 0.19, opacity: 0.86) : Color(white: 1, opacity: 0.66)
    }

    private var pillColor: Color {
        switch pill {
        case .rest: c.theme.pill
        case .hover: Color(nsColor: Palette.pillHover)
        case .pressed: Color(nsColor: Palette.pillPress)
        }
    }
}

/// One card: the app's own CardView for text, the image card's layout for photos, with the
/// selection ring 2 pt outside it, as in the panel.
struct StageCard: View {
    let clip: Clip
    let c: StageContext
    var state = CardState()
    var look: CardLook?
    var ring = false
    /// Lifted by a drag: the opaque drag-preview card, no ring, no buttons.
    var preview = false
    var fx = CardFx()

    var body: some View {
        // The face redraws only when its card changes, not on every frame of the loop.
        EquatableView(content: StageCardFace(clip: clip, c: c, state: state, look: look, preview: preview))
            .overlay {
                if ring {
                    RoundedRectangle(cornerRadius: 16.5, style: .continuous)
                        .strokeBorder(c.theme.accentRing, lineWidth: c.theme.ringWidth)
                        .padding(-4.5)
                }
            }
            .fx(fx)
    }
}

private struct StageCardFace: View, Equatable {
    let clip: Clip
    let c: StageContext
    let state: CardState
    let look: CardLook?
    let preview: Bool

    nonisolated static func == (a: StageCardFace, b: StageCardFace) -> Bool {
        a.clip.id == b.clip.id && a.state == b.state && a.preview == b.preview && a.look === b.look
            && a.c.theme.increaseContrast == b.c.theme.increaseContrast
            && a.c.theme.reduceTransparency == b.c.theme.reduceTransparency
            && a.c.theme.reduceMotion == b.c.theme.reduceMotion
    }

    var body: some View {
        if let style = c.photo(clip.id) {
            PhotoCardFace(clip: clip, style: style, state: state, c: c)
        } else {
            CardView(clip: clip, state: state, geometry: c.geometry, theme: c.theme, now: c.now, preview: preview, look: look)
        }
    }
}

/// The image card's layout (CardView's image branch) with a drawn photo, so no file is read.
struct PhotoCardFace: View {
    let clip: Clip
    let style: StagePhoto.Style
    let state: CardState
    let c: StageContext

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelGeometry.cardRadius, style: .continuous)
        let w = StageGeo.cardW, h = StageGeo.cardH
        ZStack(alignment: .topLeading) {
            shape.fill(c.theme.cardFill)
            shape.strokeBorder(c.theme.cardHair, lineWidth: 0.5)
            if let border = c.theme.cardBorder { shape.strokeBorder(border, lineWidth: 1) }
            if state.hovered { shape.fill(c.theme.hover) }
            StagePhoto(style: style)
                .frame(width: w - 12, height: h - 26 - 6)
                .overlay(alignment: .bottomTrailing) {
                    Text(ClipText.dimensions(style.pixels.0, style.pixels.1))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(height: 13)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(0.45)))
                        .padding(4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .offset(x: 6, y: 26)
            HStack(spacing: 6) {
                Image(nsImage: AppIcons.icon(for: clip.sourceBundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                Text(ClipText.time(clip.createdAt, now: c.now))
                    .font(.system(size: 11))
                    .foregroundStyle(c.theme.label2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .frame(width: w, height: 26)
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }
}

/// A drawn photograph: simple landscapes in vector shapes, so they stay sharp at any size.
struct StagePhoto: View {
    enum Style {
        case sunset, lake, dunes, bloom
        var pixels: (Int, Int) {
            switch self {
            case .sunset: (4032, 3024)
            case .lake: (3840, 2160)
            case .dunes: (2048, 1365)
            case .bloom: (3024, 4032)
            }
        }
    }

    let style: Style

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let full = Path(CGRect(origin: .zero, size: size))
            func hills(_ base: CGFloat, _ amp: CGFloat, _ phase: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: 0, y: h * base))
                p.addCurve(to: CGPoint(x: w, y: h * (base - amp * 0.4)),
                           control1: CGPoint(x: w * (0.3 + phase), y: h * (base - amp)),
                           control2: CGPoint(x: w * (0.6 + phase), y: h * (base + amp)))
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
                return p
            }
            func grad(_ a: Color, _ b: Color) -> GraphicsContext.Shading {
                .linearGradient(Gradient(colors: [a, b]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h))
            }
            switch style {
            case .sunset:
                ctx.fill(full, with: grad(Color(red: 0.98, green: 0.62, blue: 0.36), Color(red: 0.86, green: 0.35, blue: 0.45)))
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.55, y: h * 0.32, width: h * 0.34, height: h * 0.34)),
                         with: .color(Color(red: 1, green: 0.88, blue: 0.62)))
                ctx.fill(hills(0.66, 0.16, 0), with: .color(Color(red: 0.42, green: 0.20, blue: 0.33)))
                ctx.fill(hills(0.80, 0.10, 0.1), with: .color(Color(red: 0.24, green: 0.12, blue: 0.22)))
            case .lake:
                ctx.fill(full, with: grad(Color(red: 0.55, green: 0.76, blue: 0.95), Color(red: 0.82, green: 0.90, blue: 0.97)))
                ctx.fill(hills(0.55, 0.22, -0.1), with: .color(Color(red: 0.30, green: 0.52, blue: 0.40)))
                ctx.fill(Path(CGRect(x: 0, y: h * 0.66, width: w, height: h * 0.34)),
                         with: grad(Color(red: 0.25, green: 0.55, blue: 0.66), Color(red: 0.15, green: 0.38, blue: 0.52)))
            case .dunes:
                ctx.fill(full, with: grad(Color(red: 0.98, green: 0.86, blue: 0.68), Color(red: 0.96, green: 0.76, blue: 0.55)))
                ctx.fill(hills(0.58, 0.30, 0.05), with: .color(Color(red: 0.88, green: 0.58, blue: 0.34)))
                ctx.fill(hills(0.78, 0.20, -0.15), with: .color(Color(red: 0.72, green: 0.42, blue: 0.24)))
            case .bloom:
                ctx.fill(full, with: grad(Color(red: 0.36, green: 0.50, blue: 0.36), Color(red: 0.22, green: 0.34, blue: 0.24)))
                let c = CGPoint(x: w * 0.5, y: h * 0.48), r = h * 0.2
                for k in 0..<6 {
                    let a = Double(k) * .pi / 3
                    let pc = CGPoint(x: c.x + cos(a) * r * 0.9, y: c.y + sin(a) * r * 0.9)
                    ctx.fill(Path(ellipseIn: CGRect(x: pc.x - r * 0.7, y: pc.y - r * 0.7, width: r * 1.4, height: r * 1.4)),
                             with: .color(Color(red: 0.97, green: 0.55, blue: 0.58)))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.5, y: c.y - r * 0.5, width: r, height: r)),
                         with: .color(Color(red: 1, green: 0.84, blue: 0.40)))
            }
        }
    }
}

// MARK: Keys and pointer

/// A keyboard key: the card fill with a 1 pt lower edge. Pressed flips darker in one frame and
/// loses its edge; the dip comes from `scale`.
struct Keycap: View {
    let label: String
    var large = false
    var pressed = false
    var scale = 1.0
    let theme: Theme

    var body: some View {
        let h: CGFloat = large ? 40 : 24
        let shape = RoundedRectangle(cornerRadius: large ? 9 : 6, style: .continuous)
        Text(label)
            .font(.system(size: large ? 18 : 12, weight: .medium))
            .foregroundStyle(theme.label)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, large ? 12 : 7)
            .frame(minWidth: h)
            .frame(height: h)
            .background {
                ZStack {
                    shape.fill(theme.cardFill)
                    if pressed { shape.fill(theme.press) }
                }
                .shadow(color: Color(nsColor: Palette.ink(0.18, 0.55)), radius: 0, x: 0, y: pressed ? 0 : 1)
            }
            .overlay(shape.strokeBorder(theme.cardBorder ?? theme.cardHair, lineWidth: theme.cardBorder == nil ? 0.5 : 1))
            .scaleEffect(scale)
            .accessibilityLabel(KeySpeech.name(label))
    }
}

/// Keys shown briefly on the stage as they are pressed: born blurred, each press a one-frame
/// flip and a 0.92 dip, then gone, accelerating.
struct KeyHUD: View {
    let keys: [String]
    let t: Double
    let born: Double
    let leave: Double
    let presses: [Double]
    var hold = 0.16
    var large = false
    let theme: Theme

    var body: some View {
        let last = presses.last { t >= $0 }
        let down = last.map { t < $0 + hold } ?? false
        let s = last.map { VT.dip(t - $0, release: hold, depth: Motion.dipControl) } ?? 1
        HStack(spacing: large ? 8 : 5) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Keycap(label: k, large: large, pressed: down, scale: s, theme: theme)
            }
        }
        .fx(VT.born(t - born, blur: 12, scale: 1.06, lift: 0) + VT.gone(t - leave, ms: 160, blur: 10, scale: 1))
    }
}

/// The system's arrow pointer, placed by its hot spot.
struct StagePointer: View {
    let at: CGPoint
    var opacity = 1.0

    var body: some View {
        let image = NSCursor.arrow.image
        let hot = NSCursor.arrow.hotSpot
        Image(nsImage: image)
            .interpolation(.high)
            .frame(width: image.size.width, height: image.size.height)
            .offset(x: at.x - hot.x, y: at.y - hot.y)
            .opacity(opacity)
    }
}

/// VoiceOver names for keycap symbols.
enum KeySpeech {
    static func name(_ k: String) -> String {
        switch k {
        case "⌘": "Command"
        case "⌃": "Control"
        case "⌥": "Option"
        case "⇧": "Shift"
        case "⌫": "Delete"
        case "↩": "Return"
        case "←": "Left arrow"
        case "→": "Right arrow"
        case ",": "Comma"
        default: k
        }
    }

    /// "⌃⌘V" → ["⌃", "⌘", "V"]: each modifier a key, the rest one key.
    static func keys(_ label: String) -> [String] {
        var keys: [String] = []
        var rest = Substring(label)
        while let ch = rest.first, "⌃⌥⇧⌘".contains(ch) {
            keys.append(String(ch))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { keys.append(String(rest)) }
        return keys
    }
}

/// A small window on the stage (an app you copy from or drop into): title bar with three dots.
struct MiniWindow<Content: View>: View {
    let theme: Theme
    let size: CGSize
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(nsColor: Palette.ink(0.16, 0.22))).frame(width: 6, height: 6) }
            }
            .padding(.leading, 8)
            .frame(height: 18)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(shape.fill(scheme == .dark ? Color(white: 0.17) : Color.white))
        .overlay(shape.strokeBorder(theme.cardBorder ?? Color(nsColor: Palette.ink(0.10, 0.14)), lineWidth: theme.cardBorder == nil ? 0.5 : 1))
        .clipShape(shape)
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10), radius: 5, y: 2)
    }
}

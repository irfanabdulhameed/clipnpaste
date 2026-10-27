import AppKit
import SwiftUI
import ClipnpasteCore

/// One clip in the Clips grid: the panel's own `CardView`, with the panel's selection ring, select
/// pop, press dip and button pop. The card stays a picture; this wrapper turns the pointer into
/// model calls, as the panel controller does for the row.
struct ClipsCard: View {
    let clip: Clip
    let model: ClipsModel
    /// Called on mouse down, so the grid takes the keyboard.
    let focusGrid: () -> Void
    @State private var press: Press?

    private struct Press: Equatable {
        let button: CardButton?
    }

    private static var size: CGSize {
        CGSize(width: ClipsModel.geometry.cardWidth, height: ClipsModel.geometry.cardHeight)
    }

    var body: some View {
        let motion = model.motion(for: clip.id)
        let state = model.state(for: clip.id)
        let selected = model.selection.contains(clip.id)
        let theme = model.theme
        CardView(clip: clip, state: state, geometry: ClipsModel.geometry, theme: theme, now: model.now,
                 onMissing: { model.markMissing($0) }, look: motion.look)
            .overlay {
                if selected { ring(theme: theme, focused: model.ringFocused) }
            }
            .scaleEffect(motion.scale)
            .contentShape(RoundedRectangle(cornerRadius: PanelGeometry.cardRadius, style: .continuous))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    model.hover(clip.id, button: Self.button(at: p, shown: true))
                case .ended:
                    if model.hovered == clip.id { model.hover(nil, button: nil) }
                }
            }
            .gesture(pressGesture)
            .contextMenu { menu }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: "Copy") { model.copy(clip.id) }
            .accessibilityAction(named: clip.kind == .text ? "Edit Text" : "Show in Finder") { model.open(clip.id) }
            .accessibilityAction(named: "Delete") { model.delete([clip.id]) }
            .onAppear { motion.visible = true }
            .onDisappear {
                motion.visible = false
                model.forget(clip.id)
            }
    }

    /// The panel's ring: one accent outline, 2.5 pt (3.5 with Increase Contrast), 2 pt outside the
    /// card. Grey while the grid doesn't have the keyboard, as a list's selection does.
    private func ring(theme: Theme, focused: Bool) -> some View {
        let w = theme.ringWidth
        let color = focused ? Color(nsColor: .controlAccentColor) : theme.label3
        return RoundedRectangle(cornerRadius: 14 + w, style: .continuous)
            .strokeBorder(color, lineWidth: w)
            .padding(-(2 + w))
            .allowsHitTesting(false)
    }

    /// Mouse down selects at once (a double click opens on release); held, the card dips. On a
    /// button, the button dips and acts on release inside it.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if press == nil {
                    let button = Self.button(at: v.startLocation, shown: true)
                    press = Press(button: button)
                    let flags = NSEvent.modifierFlags
                    focusGrid()
                    model.pressDown(clip.id, button: button, command: flags.contains(.command), shift: flags.contains(.shift))
                }
                if let press { model.pressTracked(clip.id, button: press.button, inside: inside(v.location, press)) }
            }
            .onEnded { v in
                guard let p = press else { return }
                press = nil
                model.pressUp(clip.id, button: p.button, inside: inside(v.location, p))
            }
    }

    private func inside(_ point: CGPoint, _ press: Press) -> Bool {
        if let b = press.button { return Self.button(at: point, shown: true) == b }
        return CGRect(origin: .zero, size: Self.size).contains(point)
    }

    @ViewBuilder private var menu: some View {
        let usable = !model.missing.contains(clip.id)
        Button("Copy") { model.copy(clip.id) }.disabled(!usable)
        switch clip.kind {
        case .text: Button("Edit Text…") { model.open(clip.id) }
        case .image: Button("Show in Finder") { model.revealInFinder(clip.id) }.disabled(!usable)
        }
        Divider()
        let many = model.selection.contains(clip.id) && model.selection.count > 1
        Button(many ? "Delete \(ClipsFormat.clips(model.selection.count))" : "Delete", role: .destructive) {
            if many { model.deleteSelected() } else { model.delete([clip.id]) }
        }
    }

    /// The copy and remove buttons sit in the 26 pt header, 6 pt from the right, 4 pt apart, 20 pt
    /// round. The hit areas are 2 pt larger all round.
    static func button(at p: CGPoint, shown: Bool) -> CardButton? {
        guard shown else { return nil }
        let w = CGFloat(ClipsModel.geometry.cardWidth)
        guard p.y >= 1, p.y <= 25 else { return nil }
        let removeX = w - 6 - 20, copyX = removeX - 4 - 20
        if p.x >= removeX - 2, p.x <= removeX + 22 { return .remove }
        if p.x >= copyX - 2, p.x < removeX - 2 { return .copy }
        return nil
    }
}

/// Where the next page of clips is still loading: a plain card fill, no shimmer, as in the
/// panel's history.
struct ClipsPlaceholderCard: View {
    let theme: Theme

    var body: some View {
        RoundedRectangle(cornerRadius: PanelGeometry.cardRadius, style: .continuous)
            .fill(theme.loadFill)
            .frame(width: CGFloat(ClipsModel.geometry.cardWidth), height: CGFloat(ClipsModel.geometry.cardHeight))
            .accessibilityHidden(true)
    }
}

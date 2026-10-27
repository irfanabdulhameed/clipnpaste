import SwiftUI
import ClipnpasteCore

/// Everything the panel draws for one screen, from `CardLayout`. All whole points.
struct PanelGeometry: Equatable {
    /// From the sides and bottom of the visible frame.
    static let inset = CardLayout.margin
    static let radius: CGFloat = 24
    /// Room above the glass for its shadow.
    static let shadowRoom = 40
    /// The row's scroll area starts 22 pt down; cards sit 6 pt inside it, at the 28 pt top bar.
    static let scrollTop = 22
    static let contentTop = CardLayout.topBar - scrollTop
    static let cardRadius: CGFloat = 12
    static let header = 26
    static let footer = 20
    static let lineHeight = 16

    let layout: CardLayout
    let visibleHeight: Int
    /// Panel width: the visible width less the inset on both sides.
    let width: Int
    /// Side padding of the row; rounding leftovers land here.
    let sidePadding: Int
    /// Text lines a card shows.
    let lines: Int
    /// Card positions and the row maths for the pill, grid and history.
    let grid: PanelGrid

    init(visibleWidth: Int, visibleHeight: Int, screenHeight: Int? = nil) {
        let l = CardLayout(visibleWidth: visibleWidth, visibleHeight: visibleHeight, screenHeight: screenHeight)
        layout = l
        self.visibleHeight = visibleHeight
        width = visibleWidth - 2 * Self.inset
        sidePadding = (width - l.count * l.cardWidth - (l.count - 1) * CardLayout.gap) / 2
        lines = max(1, (l.cardHeight - Self.header - Self.footer) / Self.lineHeight)
        grid = PanelGrid(layout: l, panelWidth: width, availableHeight: visibleHeight - 2 * Self.inset)
    }

    var height: Int { layout.panelHeight }
    var cardWidth: Int { layout.cardWidth }
    var cardHeight: Int { layout.cardHeight }
    var cardTop: Int { CardLayout.topBar }
    var pitch: Int { layout.cardWidth + CardLayout.gap }
    /// More than one row fits, so the resize pill has somewhere to go.
    var canGrow: Bool { grid.maxRows > 1 }

    /// Left edge of card `index` in the row's content.
    func cardX(_ index: Int) -> Int { sidePadding + index * pitch }

    func contentWidth(count: Int) -> Int {
        count == 0 ? width : 2 * sidePadding + count * layout.cardWidth + (count - 1) * CardLayout.gap
    }

    func maxScroll(count: Int) -> CGFloat { CGFloat(max(0, contentWidth(count: count) - width)) }
}

enum CardButton: Sendable { case copy, remove }
enum FocusZone: Sendable { case card, copy, remove, history }
enum CopyMark: Sendable { case done, failed }

/// What one card shows besides its clip.
struct CardState: Equatable {
    var selected = false
    var hovered = false
    var hoveredButton: CardButton?
    var pressed = false
    var pressedButton: CardButton?
    /// Keyboard focus; only the selected card has it.
    var focus: FocusZone?
    var mark: CopyMark?
    var missing = false
    var buttonsShown: Bool { selected || hovered }
}

/// Row (one row), grid (the pill pulled up) or history (all clips by day).
enum PanelMode: Sendable, Equatable { case row, grid, history }

@MainActor @Observable
final class PanelModel {
    var geometry = PanelGeometry(visibleWidth: 1920, visibleHeight: 1050)
    var clips: [Clip] = []
    var selectedID: UUID?
    var focus: FocusZone = .card
    var hoveredCard: UUID?
    var hoveredButton: CardButton?
    var pressedCard: UUID?
    var pressedButton: CardButton?
    var marks: [UUID: CopyMark] = [:]
    var missing: Set<UUID> = []
    var needsAccessibility = false
    /// Pasteboard privacy is set to ask or deny: the second banner.
    var needsPasteboardAccess = false
    var theme = Theme()
    /// Time labels are relative to the moment the panel opened.
    var now = Date()
    var mode: PanelMode = .row
    /// All clips in the store, for the history title.
    var totalCount = 0

    @ObservationIgnored var onOpenSettings: (() -> Void)?
    /// The board's card motion: called with the old and new (card, button) when hover or press changes.
    @ObservationIgnored var onHoverChange: ((_ old: (UUID?, CardButton?), _ new: (UUID?, CardButton?)) -> Void)?
    @ObservationIgnored var onPressChange: ((_ old: (UUID?, CardButton?), _ new: (UUID?, CardButton?)) -> Void)?

    var selectedIndex: Int? { selectedID.flatMap { id in clips.firstIndex { $0.id == id } } }

    func state(for id: UUID) -> CardState {
        let isPressed = pressedCard == id
        return CardState(
            selected: selectedID == id,
            hovered: hoveredCard == id,
            hoveredButton: hoveredCard == id ? hoveredButton : nil,
            pressed: isPressed && pressedButton == nil,
            pressedButton: isPressed ? pressedButton : nil,
            focus: selectedID == id ? focus : nil,
            mark: marks[id],
            missing: missing.contains(id)
        )
    }

    func setHover(_ card: UUID?, _ button: CardButton?) {
        let old = (hoveredCard, hoveredButton)
        if hoveredCard != card { hoveredCard = card }
        if hoveredButton != button { hoveredButton = button }
        if old.0 != card || old.1 != button { onHoverChange?(old, (card, button)) }
    }

    func setPressed(_ card: UUID?, _ button: CardButton?) {
        let old = (pressedCard, pressedButton)
        if pressedCard != card { pressedCard = card }
        if pressedButton != button { pressedButton = button }
        if old.0 != card || old.1 != button { onPressChange?(old, (card, button)) }
    }

    func markMissing(_ id: UUID) {
        if !missing.contains(id) { missing.insert(id) }
    }
}

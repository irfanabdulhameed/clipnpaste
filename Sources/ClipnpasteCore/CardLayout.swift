import Foundation

/// Pure geometry for the panel. All values are whole points.
public struct CardLayout: Sendable, Equatable {
    public static let margin = 8
    public static let topBar = 28
    public static let bottomPadding = 12
    public static let gap = 12
    public static let minCount = 4
    public static let aspect = 1.6

    public let panelHeight: Int
    public let cardWidth: Int
    public let cardHeight: Int
    public let count: Int

    /// - Parameters: the screen's visible frame size in points.
    public init(visibleWidth: Int, visibleHeight: Int) {
        let g = Self.gap
        let panel = visibleHeight / 6
        let h = max(panel - Self.topBar - Self.bottomPadding, 1)
        let side = Self.margin + Self.gap
        let avail = max(visibleWidth - 2 * side, 1)
        let ideal = Double(h) * Self.aspect
        let fit = Double(avail + g) / (ideal + Double(g))
        let n = max(Int(fit.rounded()), Self.minCount)
        let w = max((avail - (n - 1) * g) / n, 1)
        panelHeight = panel
        cardHeight = h
        cardWidth = w
        count = n
    }

    /// How many card rows fit in `height` (grid mode), at least 1.
    public func rows(forHeight height: Int) -> Int {
        let usable = height - Self.topBar - Self.bottomPadding
        return max((usable + Self.gap) / (cardHeight + Self.gap), 1)
    }
}

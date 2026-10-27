import Foundation

/// Where every card sits in the panel's scroll area, and the row maths behind the resize pill.
/// Points, y down from the top of the scroll area (which starts 22 pt below the glass top).
public struct PanelGrid: Sendable, Equatable {
    /// Cards sit 6 pt into the scroll area, so 28 pt below the glass top.
    public static let contentTop = 6
    public static let scrollTop = 22
    /// History's day headers.
    public static let headerHeight = 24
    /// The thin glass strip the panel shrinks to while a card is dragged out.
    public static let stripHeight = 40
    /// A press that moves this far becomes a drag; less is a click.
    public static let dragThreshold = 4.0
    /// The panel is never taller than 3 rows (Irfan, 27 Oct 2026); more clips scroll inside it.
    public static let rowLimit = 3

    public let columns: Int
    public let cardWidth: Int
    public let cardHeight: Int
    public let sidePadding: Int
    public let maxRows: Int

    public var gap: Int { CardLayout.gap }
    public var pitchX: Int { cardWidth + gap }
    public var pitchY: Int { cardHeight + gap }

    public init(columns: Int, cardWidth: Int, cardHeight: Int, sidePadding: Int, maxRows: Int) {
        self.columns = max(columns, 1)
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.sidePadding = sidePadding
        self.maxRows = max(maxRows, 1)
    }

    /// From the card layout for a screen: `panelWidth` is the glass width, `availableHeight` the
    /// tallest the glass may be (the visible height less the insets). At most 3 rows, fewer if
    /// the screen can't fit them.
    public init(layout: CardLayout, panelWidth: Int, availableHeight: Int) {
        let pad = (panelWidth - layout.count * layout.cardWidth - (layout.count - 1) * CardLayout.gap) / 2
        self.init(columns: layout.count, cardWidth: layout.cardWidth, cardHeight: layout.cardHeight,
                  sidePadding: pad, maxRows: min(layout.rows(forHeight: availableHeight), Self.rowLimit))
    }

    // MARK: Heights

    /// Glass height that shows `rows` whole rows: 180, 332, 484… at 1080p.
    public func height(rows: Int) -> Int { CardLayout.topBar + rows * pitchY }
    public var minHeight: Int { height(rows: 1) }
    public var maxHeight: Int { height(rows: maxRows) }

    /// Rows a live height shows: a row counts once it is half uncovered.
    public func rowsShown(height: Double) -> Int {
        let k = Int(((height - Double(CardLayout.topBar)) / Double(pitchY)).rounded())
        return min(max(k, 1), maxRows)
    }

    /// Seconds of release speed the pill projects forward before picking a row.
    public static let projection = 0.12

    /// The row count the pill settles on: the height projected forward by 0.12 s of the release
    /// speed (points per second, up is positive), then the nearest whole row.
    public func snapRows(height: Double, velocity: Double) -> Int {
        rowsShown(height: height + velocity * Self.projection)
    }

    // MARK: Positions

    public struct Origin: Sendable, Equatable {
        public let x: Int, y: Int, row: Int, col: Int
        public init(x: Int, y: Int, row: Int, col: Int) { self.x = x; self.y = y; self.row = row; self.col = col }
    }

    /// Card `index` in the single row.
    public func rowOrigin(_ index: Int) -> Origin {
        Origin(x: sidePadding + index * pitchX, y: Self.contentTop, row: 0, col: index)
    }

    /// Card `index` in the grid, newest top-left, `columns` across. `top` shifts the whole grid down.
    public func gridOrigin(_ index: Int, top: Int = PanelGrid.contentTop) -> Origin {
        let col = index % columns, row = index / columns
        return Origin(x: sidePadding + col * pitchX, y: top + row * pitchY, row: row, col: col)
    }

    public func rowContentWidth(count: Int) -> Int {
        count == 0 ? 0 : 2 * sidePadding + count * cardWidth + (count - 1) * gap
    }

    public func gridRows(count: Int) -> Int { (count + columns - 1) / columns }

    public func gridContentHeight(count: Int) -> Int {
        let rows = gridRows(count: count)
        return rows == 0 ? 0 : Self.contentTop + rows * pitchY - gap + CardLayout.bottomPadding
    }

    // MARK: Reordering

    /// The slot a dragged card drops into when its top-left corner is at (`cardX`, `cardY`) in the
    /// scroll content: the nearest whole position, clamped to the `count` slots of the list.
    public func slot(cardX: Double, cardY: Double, grid: Bool, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let col = Int(((cardX - Double(sidePadding)) / Double(pitchX)).rounded())
        guard grid else { return min(max(col, 0), count - 1) }
        let c = min(max(col, 0), columns - 1)
        let r = max(Int(((cardY - Double(Self.contentTop)) / Double(pitchY)).rounded()), 0)
        return min(r * columns + c, count - 1)
    }
}

/// Past a limit the pill keeps following, with growing resistance.
public enum RubberBand {
    /// The furthest the panel can be pulled past a limit, in points.
    public static let reach = 80.0
    /// The commonly quoted iOS scroll constant (unverified).
    public static let constant = 0.55

    /// d(1 − 1/(x · c/d + 1)): how far past the limit a pull of `excess` points shows.
    public static func offset(_ excess: Double) -> Double {
        guard excess > 0 else { return 0 }
        return reach * (1 - 1 / (excess * constant / reach + 1))
    }

    /// The height shown for a raw, pointer-following height.
    public static func apply(_ raw: Double, min lo: Double, max hi: Double) -> Double {
        if raw > hi { return hi + offset(raw - hi) }
        if raw < lo { return lo - offset(lo - raw) }
        return raw
    }
}

public enum Reorder {
    /// The list as shown while a card hovers over `slot`: the card taken out and put back there.
    public static func order<T>(_ items: [T], moving from: Int, to slot: Int) -> [T] {
        guard items.indices.contains(from) else { return items }
        var out = items
        let item = out.remove(at: from)
        out.insert(item, at: min(max(slot, 0), out.count))
        return out
    }

    /// Where the `j`th of the other cards sits while the slot at `slot` is open.
    public static func displayIndex(_ j: Int, slot: Int) -> Int { j < slot ? j : j + 1 }
}

/// The drag preview's tilt (approved 27 Oct 2026): −6° on lift, plus up to ±8° from horizontal speed.
/// Negative is counter-clockwise, the top leaning left.
public enum DragTilt {
    public static let lift = -6.0
    public static let speedRange = 8.0
    /// Points per second of horizontal speed for each degree.
    public static let pointsPerSecondPerDegree = 100.0

    public static func angle(velocityX: Double) -> Double {
        lift + min(max(velocityX / pointsPerSecondPerDegree, -speedRange), speedRange)
    }
}

/// The pointer's speed from its last 100 ms of samples.
public struct VelocityTracker: Sendable {
    public struct Sample: Sendable { public let t: Double, x: Double, y: Double }
    public private(set) var samples: [Sample] = []

    public init() {}

    public mutating func add(time t: Double, x: Double, y: Double) {
        samples.append(Sample(t: t, x: x, y: y))
        while samples.count > 2, t - samples[0].t > 0.15 { samples.removeFirst() }
    }

    /// Points per second at `now`. Zero when the pointer has been still for 100 ms.
    public func velocity(at now: Double) -> (x: Double, y: Double) {
        let recent = samples.filter { now - $0.t <= 0.1 }
        guard let a = recent.first, let b = recent.last, recent.count >= 2 else { return (0, 0) }
        let dt = b.t - a.t
        guard dt >= 0.008 else { return (0, 0) }
        return ((b.x - a.x) / dt, (b.y - a.y) / dt)
    }
}

/// Scrolling while a dragged card is held near an edge of the row.
public enum AutoScroll {
    /// How close to an edge, in points, scrolling starts.
    public static let zone = 56.0
    /// Points per second with the pointer at the edge.
    public static let maxSpeed = 1100.0

    /// Negative near `lower`, positive near `upper`, zero in between; it grows with the square of
    /// how deep into the zone the pointer is.
    public static func speed(position p: Double, lower: Double, upper: Double) -> Double {
        let intoLower = zone - (p - lower), intoUpper = zone - (upper - p)
        if intoLower > 0 { return -maxSpeed * pow(min(intoLower / zone, 1), 2) }
        if intoUpper > 0 { return maxSpeed * pow(min(intoUpper / zone, 1), 2) }
        return 0
    }
}

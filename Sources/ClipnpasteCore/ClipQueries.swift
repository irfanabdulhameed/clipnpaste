import Foundation

/// Text and image clip counts, for the settings overview.
public struct ClipCounts: Sendable, Equatable {
    public var text: Int
    public var image: Int
    public var total: Int { text + image }

    public init(text: Int = 0, image: Int = 0) {
        self.text = text
        self.image = image
    }
}

/// One app clips were copied from, and how many.
public struct SourceAppCount: Sendable, Equatable, Identifiable {
    public var bundleID: String?
    public var name: String
    public var count: Int
    public var id: String { bundleID ?? name }

    public init(bundleID: String?, name: String, count: Int) {
        self.bundleID = bundleID
        self.name = name
        self.count = count
    }
}

public enum ClipOrder: Sendable, Equatable {
    /// The panel's order: by sortKey, front first.
    case panel
    /// Newest copy first.
    case newest
}

/// A search over the stored clips: an empty text matches every clip.
public struct ClipQuery: Sendable, Equatable {
    public var text: String
    public var kind: ClipKind?
    public var order: ClipOrder

    public init(text: String = "", kind: ClipKind? = nil, order: ClipOrder = .panel) {
        self.text = text
        self.kind = kind
        self.order = order
    }

    /// Clips match when their plain text contains this, ignoring case. Empty matches all.
    public var needle: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The in-memory test of a clip against the query; the SQLite store does the same in SQL.
    public func matches(_ clip: Clip) -> Bool {
        if let kind, clip.kind != kind { return false }
        let n = needle
        guard !n.isEmpty else { return true }
        return clip.plainText.map { ClipQuery.contains($0, n) } ?? false
    }

    /// Case-insensitive substring test, shared by both stores so they agree.
    public static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive]) != nil
    }
}

extension ClipStore {
    /// Clips last copied on the calendar day of `date`.
    public func copies(onDayOf date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return copyCount(from: start, to: end)
    }

    /// The top apps over the last `days` days.
    public func topSources(lastDays days: Int, now: Date = Date(), limit: Int) -> [SourceAppCount] {
        topSources(since: now.addingTimeInterval(-Double(days) * 86_400), limit: limit)
    }
}

/// Runs the auto-clear about hourly while the app runs. Stops by itself when its store is gone.
@MainActor
final class RetentionTimer {
    /// How often auto-clear runs while the app is open.
    nonisolated static let interval: Duration = .seconds(3600)
    private var task: Task<Void, Never>?

    /// Calls `tick` every `interval` until it returns false or `stop` is called.
    func start(every interval: Duration = RetentionTimer.interval, _ tick: @escaping @MainActor () -> Bool) {
        task?.cancel()
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled || !tick() { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    var isRunning: Bool { task != nil }
}

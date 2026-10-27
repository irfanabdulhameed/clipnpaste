import Foundation

@MainActor
public final class InMemoryClipStore: ClipStore {
    /// Kept in panel order (ascending sortKey).
    private var clips: [Clip]
    private var observers: [UUID: ClipStoreObserver] = [:]
    private let ageSweep = RetentionTimer()

    /// Auto-clear, as in the SQLite store. This store owns no files, so it deletes none.
    public var maxAge: TimeInterval? {
        didSet {
            guard maxAge != oldValue else { return }
            removeExpired()
            if maxAge == nil {
                ageSweep.stop()
            } else if !ageSweep.isRunning {
                ageSweep.start { [weak self] in
                    guard let self else { return false }
                    self.removeExpired()
                    return true
                }
            }
        }
    }

    public init(clips: [Clip] = []) {
        self.clips = clips.sorted { $0.sortKey < $1.sortKey }
    }

    public var count: Int { clips.count }

    public func ordered(_ limit: Int) -> [Clip] { Array(clips.prefix(max(limit, 0))) }

    public func newestByDate(_ limit: Int) -> [Clip] {
        Array(clips.sorted { $0.createdAt > $1.createdAt }.prefix(max(limit, 0)))
    }

    public func page(before date: Date, limit: Int) async -> [Clip] {
        let older = clips.filter { $0.createdAt < date }.sorted { $0.createdAt > $1.createdAt }
        return Array(older.prefix(max(limit, 0)))
    }

    private var frontKey: Double { (clips.first?.sortKey ?? 0) - 1 }

    @discardableResult
    public func insertOrBump(_ clip: Clip) -> Clip {
        if let i = clips.firstIndex(where: { $0.contentHash == clip.contentHash }) {
            var existing = clips.remove(at: i)
            existing.createdAt = clip.createdAt
            existing.sortKey = frontKey
            clips.insert(existing, at: 0)
            notify(.bumped(existing.id))
            return existing
        }
        var new = clip
        new.sortKey = frontKey
        clips.insert(new, at: 0)
        notify(.inserted(new.id))
        return new
    }

    public func remove(id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips.remove(at: i)
        notify(.removed(id))
    }

    public func move(id: UUID, toIndex index: Int) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        var clip = clips.remove(at: i)
        let at = min(max(index, 0), clips.count)
        if clips.isEmpty {
            // keeps its key
        } else if at == 0 {
            clip.sortKey = clips[0].sortKey - 1
        } else if at == clips.count {
            clip.sortKey = clips[at - 1].sortKey + 1
        } else {
            clip.sortKey = (clips[at - 1].sortKey + clips[at].sortKey) / 2
        }
        clips.insert(clip, at: at)
        notify(.moved(id))
    }

    // MARK: Settings: summary, search and bulk changes

    public func countsByKind() -> ClipCounts {
        clips.reduce(into: ClipCounts()) { c, clip in
            if clip.kind == .text { c.text += 1 } else { c.image += 1 }
        }
    }

    public func storedImageBytes() -> Int64 {
        clips.reduce(0) { $0 + ClipFiles.fileSize($1.imageURL) + ClipFiles.fileSize($1.thumbnailURL) }
    }

    public func copyCount(from start: Date, to end: Date) -> Int {
        clips.count(where: { $0.createdAt >= start && $0.createdAt < end })
    }

    public func topSources(since date: Date, limit: Int) -> [SourceAppCount] {
        var groups: [String: (app: SourceAppCount, latest: Date)] = [:]
        for clip in clips where clip.createdAt >= date {
            guard let key = clip.sourceBundleID ?? clip.sourceAppName else { continue }
            var g = groups[key] ?? (SourceAppCount(bundleID: clip.sourceBundleID, name: "", count: 0), .distantPast)
            g.app.count += 1
            if let name = clip.sourceAppName, name > g.app.name { g.app.name = name }
            g.latest = max(g.latest, clip.createdAt)
            groups[key] = g
        }
        let sorted = groups.values.sorted { a, b in
            a.app.count != b.app.count ? a.app.count > b.app.count : a.latest > b.latest
        }
        return sorted.prefix(max(limit, 0)).map { g in
            var app = g.app
            if app.name.isEmpty { app.name = app.bundleID ?? "" }
            return app
        }
    }

    public func search(_ query: ClipQuery, offset: Int, limit: Int) -> [Clip] {
        let found = matching(query)
        let start = min(max(offset, 0), found.count)
        return Array(found[start..<min(start + max(limit, 0), found.count)])
    }

    public func count(matching query: ClipQuery) -> Int { matching(query).count }

    private func matching(_ query: ClipQuery) -> [Clip] {
        let found = clips.filter(query.matches)
        guard query.order == .newest else { return found }
        return found.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }

    public func remove(ids: [UUID]) {
        let gone = Set(ids)
        let removed = clips.filter { gone.contains($0.id) }
        guard !removed.isEmpty else { return }
        clips.removeAll { gone.contains($0.id) }
        for clip in removed { notify(.removed(clip.id)) }
    }

    public func removeAll() {
        clips = []
        notify(.reloaded)
    }

    @discardableResult
    public func updateText(id: UUID, newText: String) -> Clip? {
        guard !newText.isEmpty, let i = clips.firstIndex(where: { $0.id == id }), clips[i].kind == .text else { return nil }
        let hash = ContentHash.of(newText)
        if hash == clips[i].contentHash { return clips[i] }
        if let j = clips.firstIndex(where: { $0.contentHash == hash }) {
            var other = clips[j]
            other.sortKey = clips[i].sortKey
            other.createdAt = max(other.createdAt, clips[i].createdAt)
            clips[i] = other
            clips.remove(at: j)
            notify(.removed(id))
            notify(.updated(other.id))
            return other
        }
        clips[i].plainText = newText
        clips[i].rtfData = nil
        clips[i].htmlData = nil
        clips[i].characterCount = newText.count
        clips[i].contentHash = hash
        notify(.updated(id))
        return clips[i]
    }

    /// Removes clips last copied before `maxAge` ago.
    func removeExpired(now: Date = Date()) {
        guard let maxAge else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        let expired = clips.filter { $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        clips.removeAll { $0.createdAt < cutoff }
        for clip in expired { notify(.removed(clip.id)) }
    }

    public func addObserver(_ observer: @escaping ClipStoreObserver) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func removeObserver(_ token: UUID) { observers[token] = nil }

    private func notify(_ change: ClipStoreChange) {
        for o in observers.values { o(change) }
    }
}

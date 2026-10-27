import Foundation

@MainActor
public final class InMemoryClipStore: ClipStore {
    /// Kept in panel order (ascending sortKey).
    private var clips: [Clip]
    private var observers: [UUID: ClipStoreObserver] = [:]

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

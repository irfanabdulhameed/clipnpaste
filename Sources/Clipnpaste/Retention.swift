import Foundation
import ClipnpasteCore

/// Applies the Privacy limits (clip count, image cap, age) to the store, live, and counts what a
/// tighter limit would remove so Settings can ask first.
@MainActor
final class Retention {
    let store: any ClipStore
    private let preferences: Preferences

    init(store: any ClipStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        preferences.observe { [weak self] key in
            switch key {
            case .maxClips, .maxImageBytes, .autoClearDays: self?.apply()
            default: break
            }
        }
    }

    /// The store enforces the limits itself: deleting rows and image files the moment one tightens.
    func apply() {
        let p = preferences
        if let s = store as? SQLiteClipStore {
            if s.maxClips != p.maxClips { s.maxClips = p.maxClips }
            if s.maxImageBytes != p.maxImageBytes { s.maxImageBytes = p.maxImageBytes }
            if s.maxAge != p.maxAge { s.maxAge = p.maxAge }
        } else {
            // The in-memory store of a debug run: the same count and age rules through its API.
            let over = store.count - p.maxClips
            if over > 0 { for clip in store.newestByDate(store.count).suffix(over) { store.remove(id: clip.id) } }
            if let age = p.maxAge { Self.removeClips(olderThan: age, from: store) }
        }
    }

    /// Clips a limit of `n` would remove (the oldest by copy date).
    func removed(byMaxClips n: Int) -> Int { max(0, store.count - n) }

    /// Clips last copied more than `days` ago (0 is never).
    func removed(byDays days: Int) async -> Int {
        guard days > 0 else { return 0 }
        return await store.page(before: Date().addingTimeInterval(-Double(days) * 86_400), limit: Int.max).count
    }

    /// Bytes of image files kept now, or nil when the store keeps none on disk.
    func imageBytes() async -> Int64? {
        guard let s = store as? SQLiteClipStore else { return nil }
        let folders = [s.files.images, s.files.thumbs]
        return await Task.detached(priority: .utility) {
            var total: Int64 = 0
            let fm = FileManager.default
            for folder in folders {
                let names = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                for url in names { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            }
            return total
        }.value
    }

    /// Removes every clip and its image files.
    func clearAll() {
        if let s = store as? SQLiteClipStore {
            // A limit of 0 runs the store's own retention: one transaction, files included.
            let keep = s.maxClips
            s.maxClips = 0
            s.maxClips = keep
        } else {
            for clip in store.newestByDate(store.count) { store.remove(id: clip.id) }
        }
    }

    static func removeClips(olderThan age: TimeInterval, from store: any ClipStore) {
        Task { @MainActor in
            for clip in await store.page(before: Date().addingTimeInterval(-age), limit: Int.max) {
                store.remove(id: clip.id)
            }
        }
    }
}

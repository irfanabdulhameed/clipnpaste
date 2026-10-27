import Foundation

public enum ClipStoreChange: Sendable, Equatable {
    case inserted(UUID)
    case bumped(UUID)
    case removed(UUID)
    case moved(UUID)
    case reloaded
}

/// Observers are called on the main actor after every change.
public typealias ClipStoreObserver = @MainActor @Sendable (ClipStoreChange) -> Void

@MainActor
public protocol ClipStore: AnyObject {
    /// Panel order: by sortKey, front first.
    func ordered(_ limit: Int) -> [Clip]
    /// History order: newest created date first.
    func newestByDate(_ limit: Int) -> [Clip]
    /// History paging: clips strictly older than `date`, newest first.
    func page(before date: Date, limit: Int) async -> [Clip]
    /// Inserts the clip at the front (smallest sortKey), or, if a clip with the same hash
    /// exists, moves it to the front and updates its date. Returns the stored clip.
    @discardableResult
    func insertOrBump(_ clip: Clip) -> Clip
    func remove(id: UUID)
    /// Moves the clip so it sits at `index` in panel order. Changes only its sortKey.
    func move(id: UUID, toIndex index: Int)
    var count: Int { get }
    /// Returns a token; pass it to `removeObserver`.
    func addObserver(_ observer: @escaping ClipStoreObserver) -> UUID
    func removeObserver(_ token: UUID)
}

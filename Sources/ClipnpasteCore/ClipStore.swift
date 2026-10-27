import Foundation

public enum ClipStoreChange: Sendable, Hashable {
    case inserted(UUID)
    case bumped(UUID)
    case removed(UUID)
    case moved(UUID)
    /// The clip's text changed in place (`updateText`); it kept its id and slot.
    case updated(UUID)
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

    // MARK: Settings: summary, search and bulk changes

    /// How many text and image clips are stored.
    func countsByKind() -> ClipCounts
    /// Bytes of image files (originals and thumbnails) the clips use.
    func storedImageBytes() -> Int64
    /// Clips last copied in `start ..< end` (a copy of an existing clip refreshes its date).
    func copyCount(from start: Date, to end: Date) -> Int
    /// The apps copied from most since `date`, most first; clips with no source are left out.
    func topSources(since date: Date, limit: Int) -> [SourceAppCount]
    /// Clips whose text contains `query.text` (case-insensitive), of `query.kind`, in `query.order`.
    func search(_ query: ClipQuery, offset: Int, limit: Int) -> [Clip]
    /// How many clips `search` would return without paging.
    func count(matching query: ClipQuery) -> Int
    /// Removes the clips and their image files.
    func remove(ids: [UUID])
    /// Removes every clip and every image file.
    func removeAll()
    /// Replaces a text clip's text, keeping its slot (sortKey) and date. If another clip already
    /// holds the new text, the edited clip merges into it: the other one survives, takes the edited
    /// clip's slot and the later date. Returns the clip that now holds the text, or nil when `id` is
    /// not a text clip or `newText` is empty.
    @discardableResult
    func updateText(id: UUID, newText: String) -> Clip?
    /// Auto-clear: clips not copied for longer than this are removed, with their files. nil keeps
    /// them. Applied when set, at launch and about hourly.
    var maxAge: TimeInterval? { get set }

    /// Returns a token; pass it to `removeObserver`.
    func addObserver(_ observer: @escaping ClipStoreObserver) -> UUID
    func removeObserver(_ token: UUID)
}

import Foundation
import os

private let log = Logger(subsystem: "com.irfanabdulhameed.clipnpaste", category: "store")

/// Clips in SQLite, images as files beside it. The first 200 clips in panel order stay in
/// memory, so the panel never waits on the disk.
@MainActor
public final class SQLiteClipStore: ClipStore {
    public nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Clipnpaste", directoryHint: .isDirectory)
    }
    public nonisolated static let cacheLimit = 200
    public nonisolated static let defaultMaxClips = 5_000
    public nonisolated static let defaultMaxImageBytes: Int64 = 2_000_000_000

    public let files: ClipFiles
    /// Keep at most this many clips, the newest by date.
    public var maxClips: Int { didSet { enforceRetention() } }
    /// Keep image files (originals and thumbnails) under this many bytes, dropping the oldest images first.
    public var maxImageBytes: Int64 { didSet { enforceRetention() } }

    let db: SQLiteDatabase
    /// The first clips in panel order (ascending sortKey).
    private var cache: [Clip] = []
    private var total = 0
    private var observers: [UUID: ClipStoreObserver] = [:]

    public init(
        directory: URL,
        maxClips: Int = SQLiteClipStore.defaultMaxClips,
        maxImageBytes: Int64 = SQLiteClipStore.defaultMaxImageBytes
    ) throws {
        let files = ClipFiles(root: directory)
        try files.createDirectories()
        self.files = files
        self.maxClips = maxClips
        self.maxImageBytes = maxImageBytes
        db = try SQLiteDatabase(path: files.root.appending(path: "clips.sqlite").path)
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-8000;")
        try db.execute(Self.schema)
        total = try db.query("SELECT COUNT(*) FROM clips") { $0.int(0) ?? 0 }.first ?? 0
        cache = try fetch("ORDER BY \(Self.panelOrder) LIMIT ?", [.int(Int64(Self.cacheLimit))])
        enforceRetention()
        removeOrphanFiles()
    }

    // MARK: Reading

    public var count: Int { total }

    public func ordered(_ limit: Int) -> [Clip] {
        let n = max(limit, 0)
        if n <= cache.count || cache.count == total { return Array(cache.prefix(n)) }
        return (try? fetch("ORDER BY \(Self.panelOrder) LIMIT ?", [.int(Int64(n))])) ?? cache
    }

    public func newestByDate(_ limit: Int) -> [Clip] {
        let n = max(limit, 0)
        if cache.count == total {
            return Array(cache.sorted { $0.createdAt > $1.createdAt }.prefix(n))
        }
        return (try? fetch("ORDER BY created_at DESC, id LIMIT ?", [.int(Int64(n))])) ?? []
    }

    public func page(before date: Date, limit: Int) async -> [Clip] {
        let args: [SQLiteValue] = [.double(date.timeIntervalSinceReferenceDate), .int(Int64(max(limit, 0)))]
        return (try? fetch("WHERE created_at < ? ORDER BY created_at DESC, id LIMIT ?", args)) ?? []
    }

    // MARK: Changing

    @discardableResult
    public func insertOrBump(_ clip: Clip) -> Clip {
        do {
            if var existing = try find(hash: clip.contentHash) {
                existing.createdAt = clip.createdAt
                existing.sortKey = frontKey
                try db.run(
                    "UPDATE clips SET created_at = ?, sort_key = ? WHERE id = ?",
                    [.double(existing.createdAt.timeIntervalSinceReferenceDate), .double(existing.sortKey), .text(existing.id.uuidString)]
                )
                // The incoming copy's own files, if it brought different ones, are not needed.
                if clip.imageURL != existing.imageURL { files.delete(clip.imageURL) }
                if clip.thumbnailURL != existing.thumbnailURL { files.delete(clip.thumbnailURL) }
                cache.removeAll { $0.id == existing.id }
                cache.insert(existing, at: 0)
                trimCache()
                notify(.bumped(existing.id))
                return existing
            }
            var new = clip
            new.sortKey = frontKey
            try db.run(
                "INSERT INTO clips (\(Self.columns)) VALUES (\(Array(repeating: "?", count: 16).joined(separator: ", ")))",
                values(new)
            )
            total += 1
            cache.insert(new, at: 0)
            trimCache()
            notify(.inserted(new.id))
            enforceRetention()
            return new
        } catch {
            log.error("insert failed: \(String(describing: error), privacy: .public)")
            return clip
        }
    }

    public func remove(id: UUID) {
        guard let clip = try? find(id: id) else { return }
        do {
            try db.run("DELETE FROM clips WHERE id = ?", [.text(id.uuidString)])
        } catch {
            log.error("remove failed: \(String(describing: error), privacy: .public)")
            return
        }
        deleteFiles(of: clip)
        total -= 1
        cache.removeAll { $0.id == id }
        refillCache()
        notify(.removed(id))
    }

    public func move(id: UUID, toIndex index: Int) {
        guard var clip = try? find(id: id) else { return }
        let others = total - 1
        let at = min(max(index, 0), others)
        if others > 0 {
            do {
                clip.sortKey = try sortKey(forSlot: at, of: id, others: others)
                try db.run("UPDATE clips SET sort_key = ? WHERE id = ?", [.double(clip.sortKey), .text(id.uuidString)])
            } catch {
                log.error("move failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        cache.removeAll { $0.id == id }
        if at < Self.cacheLimit, at <= cache.count { cache.insert(clip, at: at) }
        trimCache()
        refillCache()
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

    // MARK: Order

    private static let panelOrder = "sort_key, created_at DESC, id"

    private var frontKey: Double { (cache.first?.sortKey ?? 0) - 1 }

    /// A key that places a clip at `at` among the others. Only the moved clip changes,
    /// unless the gap has run out of precision; then every clip is spaced out once.
    private func sortKey(forSlot at: Int, of id: UUID, others: Int, renumbered: Bool = false) throws -> Double {
        let keys = try db.query(
            "SELECT sort_key FROM clips WHERE id != ? ORDER BY \(Self.panelOrder) LIMIT ? OFFSET ?",
            [.text(id.uuidString), .int(at == 0 ? 1 : 2), .int(Int64(max(at - 1, 0)))]
        ) { $0.double(0) ?? 0 }
        if at == 0 { return (keys.first ?? 0) - 1 }
        if at == others { return (keys.first ?? 0) + 1 }
        guard keys.count == 2 else { return (keys.first ?? 0) + 1 }
        let mid = (keys[0] + keys[1]) / 2
        if (mid > keys[0] && mid < keys[1]) || renumbered { return mid }
        try renumber(except: id)
        return try sortKey(forSlot: at, of: id, others: others, renumbered: true)
    }

    private func renumber(except id: UUID) throws {
        let ids = try db.query(
            "SELECT id FROM clips WHERE id != ? ORDER BY \(Self.panelOrder)", [.text(id.uuidString)]
        ) { $0.string(0) ?? "" }
        try db.transaction {
            for (i, other) in ids.enumerated() {
                try db.run("UPDATE clips SET sort_key = ? WHERE id = ?", [.double(Double(i)), .text(other)])
            }
        }
        cache = try fetch("ORDER BY \(Self.panelOrder) LIMIT ?", [.int(Int64(Self.cacheLimit))])
    }

    private func trimCache() {
        if cache.count > Self.cacheLimit { cache.removeLast(cache.count - Self.cacheLimit) }
    }

    /// Tops the cache back up to the first 200 after clips left it.
    private func refillCache() {
        let want = min(Self.cacheLimit, total)
        guard cache.count < want else { return }
        let more = try? fetch(
            "ORDER BY \(Self.panelOrder) LIMIT ? OFFSET ?", [.int(Int64(want - cache.count)), .int(Int64(cache.count))]
        )
        cache += more ?? []
    }

    // MARK: Retention

    /// Keeps the newest `maxClips`, then drops the oldest images until their files fit `maxImageBytes`.
    private func enforceRetention() {
        do {
            var doomed: [Clip] = []
            var doomedBytes: Int64 = 0
            if total > maxClips {
                let rows = try fetchWithBytes("ORDER BY created_at, id LIMIT ?", [.int(Int64(total - maxClips))])
                doomed = rows.map(\.clip)
                doomedBytes = rows.reduce(0) { $0 + $1.bytes }
            }
            let stored = try db.query("SELECT COALESCE(SUM(image_bytes), 0) FROM clips") { $0.int64(0) }.first ?? 0
            var bytes = stored - doomedBytes
            if bytes > maxImageBytes {
                let gone = Set(doomed.map(\.id))
                for row in try fetchWithBytes("WHERE image_bytes > 0 ORDER BY created_at, id")
                where bytes > maxImageBytes && !gone.contains(row.clip.id) {
                    doomed.append(row.clip)
                    bytes -= row.bytes
                }
            }
            guard !doomed.isEmpty else { return }
            try db.transaction {
                for clip in doomed { try db.run("DELETE FROM clips WHERE id = ?", [.text(clip.id.uuidString)]) }
            }
            for clip in doomed { deleteFiles(of: clip) }
            total -= doomed.count
            let ids = Set(doomed.map(\.id))
            cache.removeAll { ids.contains($0.id) }
            refillCache()
            for clip in doomed { notify(.removed(clip.id)) }
        } catch {
            log.error("retention failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func deleteFiles(of clip: Clip) {
        files.delete(clip.imageURL)
        files.delete(clip.thumbnailURL)
    }

    /// Deletes image files no row points at, left by a crash between writing and inserting.
    private func removeOrphanFiles() {
        let sql = "SELECT image_path, thumbnail_path FROM clips WHERE image_path IS NOT NULL OR thumbnail_path IS NOT NULL"
        let paths: [[String?]]
        do { paths = try db.query(sql) { [$0.string(0), $0.string(1)] } } catch { return }
        let referenced = Set(paths.flatMap { $0 }.compactMap { $0 })
        let fm = FileManager.default
        for dir in ["images", "thumbs"] {
            let names = (try? fm.contentsOfDirectory(atPath: files.root.appending(path: dir).path)) ?? []
            for name in names where !referenced.contains("\(dir)/\(name)") {
                try? fm.removeItem(at: files.root.appending(path: dir).appending(path: name))
            }
        }
    }

    // MARK: Rows

    private static let schema = """
        CREATE TABLE IF NOT EXISTS clips (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            plain_text TEXT,
            rtf BLOB,
            html BLOB,
            image_path TEXT,
            thumbnail_path TEXT,
            pixel_width INTEGER,
            pixel_height INTEGER,
            character_count INTEGER NOT NULL,
            source_bundle_id TEXT,
            source_app_name TEXT,
            created_at REAL NOT NULL,
            sort_key REAL NOT NULL,
            content_hash TEXT NOT NULL UNIQUE,
            image_bytes INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS clips_by_sort ON clips(sort_key);
        CREATE INDEX IF NOT EXISTS clips_by_date ON clips(created_at);
        PRAGMA user_version = 1;
        """

    private static let columns = """
        id, kind, plain_text, rtf, html, image_path, thumbnail_path, pixel_width, pixel_height, \
        character_count, source_bundle_id, source_app_name, created_at, sort_key, content_hash, image_bytes
        """

    private func values(_ c: Clip) -> [SQLiteValue] {
        let bytes = ClipFiles.fileSize(c.imageURL) + ClipFiles.fileSize(c.thumbnailURL)
        return [
            .text(c.id.uuidString), .text(c.kind.rawValue), .of(c.plainText), .of(c.rtfData), .of(c.htmlData),
            .of(c.imageURL.map(files.storedPath)), .of(c.thumbnailURL.map(files.storedPath)),
            .of(c.pixelWidth), .of(c.pixelHeight), .int(Int64(c.characterCount)),
            .of(c.sourceBundleID), .of(c.sourceAppName),
            .double(c.createdAt.timeIntervalSinceReferenceDate), .double(c.sortKey), .text(c.contentHash),
            .int(bytes),
        ]
    }

    private func clip(_ r: SQLiteRow) -> Clip {
        Clip(
            id: r.string(0).flatMap(UUID.init(uuidString:)) ?? UUID(),
            kind: r.string(1).flatMap(ClipKind.init(rawValue:)) ?? .text,
            plainText: r.string(2),
            rtfData: r.data(3),
            htmlData: r.data(4),
            imageURL: r.string(5).map(files.url(forStoredPath:)),
            thumbnailURL: r.string(6).map(files.url(forStoredPath:)),
            pixelWidth: r.int(7),
            pixelHeight: r.int(8),
            characterCount: r.int(9) ?? 0,
            sourceBundleID: r.string(10),
            sourceAppName: r.string(11),
            createdAt: Date(timeIntervalSinceReferenceDate: r.double(12) ?? 0),
            sortKey: r.double(13) ?? 0,
            contentHash: r.string(14) ?? ""
        )
    }

    private func fetch(_ tail: String, _ args: [SQLiteValue] = []) throws -> [Clip] {
        try db.query("SELECT \(Self.columns) FROM clips \(tail)", args, clip)
    }

    private func fetchWithBytes(_ tail: String, _ args: [SQLiteValue] = []) throws -> [(clip: Clip, bytes: Int64)] {
        try db.query("SELECT \(Self.columns) FROM clips \(tail)", args) { (clip($0), $0.int64(15)) }
    }

    private func find(hash: String) throws -> Clip? {
        if let c = cache.first(where: { $0.contentHash == hash }) { return c }
        return try fetch("WHERE content_hash = ?", [.text(hash)]).first
    }

    private func find(id: UUID) throws -> Clip? {
        if let c = cache.first(where: { $0.id == id }) { return c }
        return try fetch("WHERE id = ?", [.text(id.uuidString)]).first
    }
}

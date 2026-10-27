import Testing
import Foundation
@testable import ClipnpasteCore

@MainActor @Suite struct SQLiteClipStoreTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// `n` text clips, inserted oldest first, so the newest is at the front.
    func filled(_ store: SQLiteClipStore, _ n: Int) {
        for i in (0..<n).reversed() {
            store.insertOrBump(.text("clip \(i)", at: now.addingTimeInterval(-Double(i) * 60)))
        }
    }

    func imageClip(_ store: SQLiteClipStore, gray: CGFloat, at date: Date) throws -> Clip {
        let png = TestImages.png(width: 40, height: 30, gray: gray)
        return try ClipBuilder.make(.imageData(png, type: PasteboardTypes.png), source: nil, date: date, files: store.files)
    }

    @Test func defaultDirectory() {
        #expect(SQLiteClipStore.defaultDirectory.path.hasSuffix("Library/Application Support/Clipnpaste"))
    }

    @Test func createsItsFolders() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        #expect(FileManager.default.fileExists(atPath: store.files.images.path))
        #expect(FileManager.default.fileExists(atPath: store.files.thumbs.path))
        #expect(FileManager.default.fileExists(atPath: dir.url.appending(path: "clips.sqlite").path))
    }

    // MARK: Hashing and insert-or-bump

    @Test func insertPutsNewestFirst() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        var changes: [ClipStoreChange] = []
        _ = store.addObserver { changes.append($0) }
        filled(store, 3)
        #expect(store.count == 3)
        #expect(store.ordered(10).map(\.plainText) == ["clip 0", "clip 1", "clip 2"])
        #expect(changes.count == 3 && changes.allSatisfy { if case .inserted = $0 { true } else { false } })
    }

    @Test func sameHashBumpsToFrontAndRefreshesDate() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        filled(store, 5)
        let old = store.ordered(5).last!
        var changes: [ClipStoreChange] = []
        _ = store.addObserver { changes.append($0) }
        let later = now.addingTimeInterval(3600)
        let result = store.insertOrBump(.text(old.plainText!, at: later))
        #expect(result.id == old.id)
        #expect(store.count == 5)
        #expect(store.ordered(1).first?.id == old.id)
        #expect(store.ordered(1).first?.createdAt == later)
        #expect(store.newestByDate(1).first?.id == old.id)
        #expect(changes == [.bumped(old.id)])
    }

    @Test func bumpReachesClipsOutsideTheCache() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        filled(store, 230)
        let deep = store.ordered(230)[220]
        store.insertOrBump(.text(deep.plainText!, at: now.addingTimeInterval(60)))
        #expect(store.count == 230)
        #expect(store.ordered(1).first?.id == deep.id)
        #expect(Set(store.ordered(300).map(\.id)).count == 230)
    }

    // MARK: Move

    @Test func moveKeepsOthersInOrderAndTouchesOneRow() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        filled(store, 12)
        let before = store.ordered(100)
        var changes: [ClipStoreChange] = []
        _ = store.addObserver { changes.append($0) }
        let writes = store.db.totalChanges
        store.move(id: before[0].id, toIndex: 5)
        #expect(store.db.totalChanges - writes == 1)
        var expected = before.map(\.id)
        expected.remove(at: 0)
        expected.insert(before[0].id, at: 5)
        let after = store.ordered(100)
        #expect(after.map(\.id) == expected)
        // Every other clip keeps its key.
        let keys = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.sortKey) })
        #expect(after.filter { $0.id != before[0].id }.allSatisfy { keys[$0.id] == $0.sortKey })
        #expect(changes == [.moved(before[0].id)])
    }

    @Test func newCopyLandsFirstAfterMove() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        filled(store, 12)
        let ids = store.ordered(100).map(\.id)
        store.move(id: ids[3], toIndex: 0)
        store.move(id: ids[0], toIndex: 11)
        let fresh = store.insertOrBump(.text("fresh", at: now.addingTimeInterval(60)))
        #expect(store.ordered(2).map(\.id) == [fresh.id, ids[3]])
        #expect(store.ordered(100).last?.id == ids[0])
        #expect(store.newestByDate(1).first?.id == fresh.id)
    }

    @Test func movesAcrossTheCacheEdgeMatchAnArray() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        filled(store, 250)
        var expected = store.ordered(250).map(\.id)
        for (from, to) in [(240, 0), (5, 230), (199, 200), (200, 199), (0, 249), (100, 300), (249, -3)] {
            let id = expected.remove(at: from)
            expected.insert(id, at: min(max(to, 0), expected.count))
            store.move(id: id, toIndex: to)
            #expect(store.ordered(250).map(\.id) == expected)
            #expect(store.ordered(10).map(\.id) == Array(expected.prefix(10)))
        }
    }

    @Test func repeatedMovesIntoOneGapKeepOrder() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        filled(store, 80)
        var expected = store.ordered(80).map(\.id)
        // Each move halves the same gap; past about 50 halvings the keys are spaced out again.
        for i in 2..<80 {
            let id = expected.remove(at: i)
            expected.insert(id, at: 1)
            store.move(id: id, toIndex: 1)
        }
        #expect(store.ordered(80).map(\.id) == expected)
        #expect(Set(store.ordered(80).map(\.sortKey)).count == 80)
    }

    @Test func removeDropsTheRowAndRefillsTheCache() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        filled(store, 205)
        let all = store.ordered(205).map(\.id)
        var changes: [ClipStoreChange] = []
        _ = store.addObserver { changes.append($0) }
        store.remove(id: all[0])
        store.remove(id: all[204])
        #expect(store.count == 203)
        #expect(store.ordered(203).map(\.id) == Array(all[1..<204]))
        #expect(store.ordered(200).map(\.id) == Array(all[1...200]))
        #expect(changes == [.removed(all[0]), .removed(all[204])])
    }

    // MARK: History paging

    @Test func pagingByDate() async throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        filled(store, 10)
        // A manual move must not change history order.
        let ids = store.ordered(10).map(\.id)
        store.move(id: ids[7], toIndex: 0)
        #expect(store.newestByDate(3).map(\.plainText) == ["clip 0", "clip 1", "clip 2"])
        let page = await store.page(before: now.addingTimeInterval(-120), limit: 4)
        #expect(page.map(\.plainText) == ["clip 3", "clip 4", "clip 5", "clip 6"])
        let last = await store.page(before: page.last!.createdAt, limit: 4)
        #expect(last.map(\.plainText) == ["clip 7", "clip 8", "clip 9"])
        #expect(await store.page(before: last.last!.createdAt, limit: 4).isEmpty)
    }

    @Test func newestByDateBeyondTheCache() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        filled(store, 210)
        store.move(id: store.ordered(1)[0].id, toIndex: 209)
        let newest = store.newestByDate(210)
        #expect(newest.count == 210)
        #expect(newest.first?.plainText == "clip 0")
        #expect(zip(newest, newest.dropFirst()).allSatisfy { $0.createdAt > $1.createdAt })
    }

    // MARK: Retention

    @Test func retentionByCount() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url, maxClips: 3)
        let image = try imageClip(store, gray: 0.2, at: now.addingTimeInterval(-3600))
        store.insertOrBump(image)
        var changes: [ClipStoreChange] = []
        _ = store.addObserver { changes.append($0) }
        filled(store, 4)
        #expect(store.count == 3)
        #expect(store.ordered(10).map(\.plainText) == ["clip 0", "clip 1", "clip 2"])
        #expect(changes.contains(.removed(image.id)))
        #expect(!FileManager.default.fileExists(atPath: image.imageURL!.path))
        #expect(!FileManager.default.fileExists(atPath: image.thumbnailURL!.path))
    }

    @Test func retentionByImageBytesDropsOldestImagesFirst() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        let images = try [0.1, 0.4, 0.7].enumerated().map { i, gray in
            try imageClip(store, gray: gray, at: now.addingTimeInterval(Double(i) * 60))
        }
        let sizes = images.map { ClipFiles.fileSize($0.imageURL) + ClipFiles.fileSize($0.thumbnailURL) }
        #expect(sizes.allSatisfy { $0 > 0 })
        store.insertOrBump(.text("old text", at: now.addingTimeInterval(-600)))
        images.forEach { store.insertOrBump($0) }
        #expect(store.count == 4)
        // Room for the two newest images only.
        store.maxImageBytes = sizes[1] + sizes[2]
        #expect(store.count == 3)
        let left = store.ordered(10)
        #expect(left.map(\.id) == [images[2].id, images[1].id, left[2].id])
        #expect(left[2].plainText == "old text")
        #expect(!FileManager.default.fileExists(atPath: images[0].imageURL!.path))
        #expect(!FileManager.default.fileExists(atPath: images[0].thumbnailURL!.path))
        #expect(FileManager.default.fileExists(atPath: images[2].imageURL!.path))
    }

    @Test func removeDeletesFiles() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        let image = store.insertOrBump(try imageClip(store, gray: 0.3, at: now))
        #expect(FileManager.default.fileExists(atPath: image.imageURL!.path))
        store.remove(id: image.id)
        #expect(store.count == 0)
        #expect(!FileManager.default.fileExists(atPath: image.imageURL!.path))
        #expect(!FileManager.default.fileExists(atPath: image.thumbnailURL!.path))
    }

    // MARK: Persistence

    @Test func persistsAcrossReopening() throws {
        let dir = TempDir()
        defer { dir.remove() }
        var saved: [Clip] = []
        do {
            let store = try SQLiteClipStore(directory: dir.url)
            filled(store, 6)
            store.insertOrBump(Clip(
                kind: .text, plainText: "rich\u{0}text", rtfData: Data("{\\rtf1 rich}".utf8), htmlData: Data(),
                sourceBundleID: "com.apple.TextEdit", sourceAppName: "TextEdit", createdAt: now.addingTimeInterval(30),
                contentHash: ContentHash.of("rich\u{0}text")
            ))
            store.insertOrBump(try imageClip(store, gray: 0.6, at: now.addingTimeInterval(60)))
            store.move(id: store.ordered(3)[2].id, toIndex: 6)
            saved = store.ordered(100)
        }
        let reopened = try SQLiteClipStore(directory: dir.url)
        #expect(reopened.count == 8)
        #expect(reopened.ordered(100) == saved)
        let image = try #require(reopened.ordered(100).first { $0.kind == .image })
        #expect(FileManager.default.fileExists(atPath: image.imageURL!.path))
        #expect(image.pixelWidth == 40 && image.pixelHeight == 30)
    }

    @Test func orphanFilesAreRemovedOnOpen() throws {
        let dir = TempDir()
        defer { dir.remove() }
        var kept: Clip?
        do {
            let store = try SQLiteClipStore(directory: dir.url)
            kept = store.insertOrBump(try imageClip(store, gray: 0.5, at: now))
            // Written but never inserted, as after a crash.
            _ = try imageClip(store, gray: 0.9, at: now)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: "images").path).count == 2)
        _ = try SQLiteClipStore(directory: dir.url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: "images").path) == [kept!.imageURL!.lastPathComponent])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: "thumbs").path).count == 1)
    }
}

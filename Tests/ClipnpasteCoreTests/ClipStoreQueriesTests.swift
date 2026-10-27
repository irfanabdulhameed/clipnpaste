import Testing
import Foundation
@testable import ClipnpasteCore

enum StoreKind: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case sqlite, memory
    var testDescription: String { rawValue }
}

/// A fresh store of either kind in its own temporary folder; call `remove()` in a `defer`.
@MainActor
struct StoreUnderTest {
    let store: any ClipStore
    let dir: TempDir
    /// Where image files are written: inside the SQLite store (so it owns them), or the folder.
    let files: ClipFiles

    init(_ kind: StoreKind) throws {
        dir = TempDir()
        switch kind {
        case .sqlite:
            let s = try SQLiteClipStore(directory: dir.url)
            store = s
            files = s.files
        case .memory:
            store = InMemoryClipStore()
            files = ClipFiles(root: dir.url.appending(path: "files", directoryHint: .isDirectory))
        }
    }

    var sqlite: SQLiteClipStore? { store as? SQLiteClipStore }

    func remove() { dir.remove() }

    @discardableResult
    func text(_ s: String, at date: Date, app: (String, String)? = nil) -> Clip {
        store.insertOrBump(Clip(kind: .text, plainText: s, sourceBundleID: app?.0, sourceAppName: app?.1,
                                createdAt: date, contentHash: ContentHash.of(s)))
    }

    @discardableResult
    func image(gray: CGFloat, at date: Date, app: (String, String)? = nil) throws -> Clip {
        let png = TestImages.png(width: 40, height: 30, gray: gray)
        let source = app.map { SourceApp(bundleID: $0.0, name: $0.1) }
        let clip = try ClipBuilder.make(.imageData(png, type: PasteboardTypes.png), source: source, date: date, files: files)
        return store.insertOrBump(clip)
    }

    func exists(_ url: URL?) -> Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func panelTexts(_ n: Int = 1000) -> [String] { store.ordered(n).map { $0.plainText ?? "<image>" } }
}

@MainActor @Suite struct ClipStoreQueriesTests {
    let now = Date()
    let safari = ("com.apple.Safari", "Safari")
    let mail = ("com.apple.mail", "Mail")
    let notes = ("com.apple.Notes", "Notes")
    let terminal = ("com.apple.Terminal", "Terminal")

    func ago(days: Double = 0, minutes: Double = 0) -> Date { now.addingTimeInterval(-days * 86_400 - minutes * 60) }

    // MARK: Summary

    @Test(arguments: StoreKind.allCases) func countsByKindAndImageBytes(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        #expect(t.store.countsByKind() == ClipCounts())
        #expect(t.store.storedImageBytes() == 0)
        t.text("one", at: ago(minutes: 3))
        t.text("two", at: ago(minutes: 2))
        t.text("three", at: ago(minutes: 1))
        let a = try t.image(gray: 0.2, at: now)
        let b = try t.image(gray: 0.7, at: now)
        let counts = t.store.countsByKind()
        #expect(counts == ClipCounts(text: 3, image: 2))
        #expect(counts.total == 5)
        let expected = [a, b].reduce(Int64(0)) { $0 + ClipFiles.fileSize($1.imageURL) + ClipFiles.fileSize($1.thumbnailURL) }
        #expect(expected > 0)
        #expect(t.store.storedImageBytes() == expected)
    }

    @Test(arguments: StoreKind.allCases) func copiesOnADay(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let day = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
        let start = cal.startOfDay(for: day)
        t.text("before midnight", at: start.addingTimeInterval(-1))
        t.text("at midnight", at: start)
        t.text("noon", at: day)
        t.text("last second", at: start.addingTimeInterval(86_399))
        t.text("next day", at: start.addingTimeInterval(86_400))
        #expect(t.store.copies(onDayOf: day, calendar: cal) == 3)
        // Copying an older clip again refreshes its date, so it counts as a copy on the new day.
        t.text("before midnight", at: day)
        #expect(t.store.copies(onDayOf: day, calendar: cal) == 4)
        #expect(t.store.copyCount(from: start, to: start) == 0)
    }

    @Test(arguments: StoreKind.allCases) func topSourcesOverTheLast30Days(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        for i in 0..<4 { t.text("old terminal \(i)", at: ago(days: 40, minutes: Double(i)), app: terminal) }
        for i in 0..<3 { t.text("safari \(i)", at: ago(days: 2, minutes: Double(i)), app: safari) }
        try t.image(gray: 0.4, at: ago(days: 1), app: mail)
        t.text("mail", at: ago(days: 5), app: mail)
        t.text("notes", at: ago(days: 20), app: notes)
        t.text("no source a", at: ago(minutes: 1))
        t.text("no source b", at: ago(minutes: 2))
        let top = t.store.topSources(lastDays: 30, now: now, limit: 5)
        #expect(top.map(\.name) == ["Safari", "Mail", "Notes"])
        #expect(top.map(\.count) == [3, 2, 1])
        #expect(top.first?.bundleID == "com.apple.Safari")
        #expect(top.first?.id == "com.apple.Safari")
        #expect(t.store.topSources(lastDays: 30, now: now, limit: 2).count == 2)
        // A tie goes to the app copied from most recently.
        t.text("notes 2", at: ago(minutes: 5), app: notes)
        #expect(t.store.topSources(lastDays: 30, now: now, limit: 5).map(\.name) == ["Safari", "Notes", "Mail"])
        #expect(t.store.topSources(lastDays: 60, now: now, limit: 1).map(\.name) == ["Terminal"])
    }

    // MARK: Search

    @Test(arguments: StoreKind.allCases) func searchIgnoresCaseAndFiltersByKind(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        t.text("Invoice 2026-118 sent to Arjun", at: ago(minutes: 9))
        t.text("second INVOICE draft", at: ago(minutes: 8))
        t.text("no match here", at: ago(minutes: 7))
        t.text("École de café", at: ago(minutes: 6))
        t.text("50% off today", at: ago(minutes: 5))
        t.text("a_b and axb", at: ago(minutes: 4))
        t.text("only axb", at: ago(minutes: 3))
        try t.image(gray: 0.3, at: ago(minutes: 2))
        try t.image(gray: 0.6, at: ago(minutes: 1))
        func texts(_ q: ClipQuery) -> [String] { t.store.search(q, offset: 0, limit: 100).map { $0.plainText ?? "<image>" } }

        #expect(texts(ClipQuery(text: "invoice")) == ["second INVOICE draft", "Invoice 2026-118 sent to Arjun"])
        #expect(t.store.count(matching: ClipQuery(text: "invoice")) == 2)
        #expect(texts(ClipQuery(text: "  Invoice  ")).count == 2)
        #expect(texts(ClipQuery(text: "école")) == ["École de café"])
        #expect(texts(ClipQuery(text: "CAFÉ")) == ["École de café"])
        #expect(texts(ClipQuery(text: "50%")) == ["50% off today"])
        #expect(texts(ClipQuery(text: "a_b")) == ["a_b and axb"])
        #expect(texts(ClipQuery(text: "%")) == ["50% off today"])
        #expect(texts(ClipQuery(text: "zzz")).isEmpty)
        #expect(t.store.count(matching: ClipQuery(text: "zzz")) == 0)

        #expect(t.store.count(matching: ClipQuery()) == 9)
        #expect(t.store.count(matching: ClipQuery(kind: .image)) == 2)
        #expect(t.store.count(matching: ClipQuery(kind: .text)) == 7)
        #expect(texts(ClipQuery(kind: .image)) == ["<image>", "<image>"])
        #expect(t.store.count(matching: ClipQuery(text: "invoice", kind: .image)) == 0)
        #expect(t.store.count(matching: ClipQuery(text: "invoice", kind: .text)) == 2)
    }

    @Test(arguments: StoreKind.allCases) func searchPagesInPanelOrderOrByDate(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        for i in (0..<250).reversed() { t.text("item \(i)", at: ago(minutes: Double(i))) }
        t.text("unrelated", at: ago(minutes: 500))
        // A manual move changes panel order but not date order.
        let moved = t.store.ordered(1).first!
        t.store.move(id: moved.id, toIndex: 240)
        let q = ClipQuery(text: "ITEM")
        #expect(t.store.count(matching: q) == 250)
        var paged: [UUID] = []
        var offset = 0
        while true {
            let page = t.store.search(q, offset: offset, limit: 64)
            if page.isEmpty { break }
            paged += page.map(\.id)
            offset += page.count
        }
        let panel = t.store.ordered(1000).filter { $0.plainText?.hasPrefix("item") ?? false }.map(\.id)
        #expect(paged == panel)
        #expect(t.store.search(q, offset: 1000, limit: 10).isEmpty)

        let newest = t.store.search(ClipQuery(text: "item", order: .newest), offset: 0, limit: 3).map(\.plainText)
        #expect(newest == ["item 0", "item 1", "item 2"])
        let second = t.store.search(ClipQuery(order: .newest), offset: 250, limit: 5).map(\.plainText)
        #expect(second == ["unrelated"])
    }

    // MARK: Removing

    @Test(arguments: StoreKind.allCases) func removeManyDropsRowsAndFiles(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        for i in (0..<230).reversed() { t.text("clip \(i)", at: ago(minutes: Double(i))) }
        let img = try t.image(gray: 0.5, at: now)
        let all = t.store.ordered(1000).map(\.id)
        var changes: [ClipStoreChange] = []
        _ = t.store.addObserver { changes.append($0) }
        // In the cache, past it, the image, an unknown id and a repeat.
        let doomed = [all[3], all[150], all[225], img.id, UUID(), all[3]]
        t.store.remove(ids: doomed)
        let gone = Set(doomed)
        #expect(t.store.count == 227)
        #expect(t.store.ordered(1000).map(\.id) == all.filter { !gone.contains($0) })
        #expect(t.store.ordered(200).map(\.id) == Array(all.filter { !gone.contains($0) }.prefix(200)))
        #expect(Set(changes) == Set([all[3], all[150], all[225], img.id].map(ClipStoreChange.removed)))
        #expect(changes.count == 4)
        if t.sqlite != nil {
            #expect(!t.exists(img.imageURL))
            #expect(!t.exists(img.thumbnailURL))
        }
        t.store.remove(ids: [])
        #expect(changes.count == 4)
    }

    @Test(arguments: StoreKind.allCases) func removeAllClearsEverything(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        for i in 0..<210 { t.text("clip \(i)", at: ago(minutes: Double(i))) }
        let img = try t.image(gray: 0.5, at: now)
        var changes: [ClipStoreChange] = []
        _ = t.store.addObserver { changes.append($0) }
        t.store.removeAll()
        #expect(t.store.count == 0)
        #expect(t.store.ordered(10).isEmpty)
        #expect(t.store.newestByDate(10).isEmpty)
        #expect(t.store.countsByKind() == ClipCounts())
        #expect(t.store.storedImageBytes() == 0)
        #expect(changes == [.reloaded])
        if let s = t.sqlite {
            #expect(!t.exists(img.imageURL))
            let fm = FileManager.default
            #expect(try fm.contentsOfDirectory(atPath: s.files.images.path).isEmpty)
            #expect(try fm.contentsOfDirectory(atPath: s.files.thumbs.path).isEmpty)
        }
        // Still usable afterwards.
        t.text("fresh", at: now)
        #expect(t.panelTexts() == ["fresh"])
    }

    // MARK: Editing

    @Test(arguments: StoreKind.allCases) func updateTextKeepsTheSlotAndRehashes(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        for i in (0..<5).reversed() {
            let s = "clip \(i)"
            // The middle clip has rich text, which an edit must drop.
            t.store.insertOrBump(Clip(kind: .text, plainText: s, rtfData: i == 2 ? Data("{\\rtf1 x}".utf8) : nil,
                                      htmlData: i == 2 ? Data("<b>x</b>".utf8) : nil,
                                      createdAt: ago(minutes: Double(i)), contentHash: ContentHash.of(s)))
        }
        let target = t.store.ordered(5)[2]
        #expect(target.rtfData != nil)
        let before = t.store.ordered(5)
        #expect(before[2].id == target.id)
        var changes: [ClipStoreChange] = []
        _ = t.store.addObserver { changes.append($0) }

        let edited = try #require(t.store.updateText(id: target.id, newText: "Edited text ✏️"))
        #expect(edited.id == target.id)
        #expect(edited.plainText == "Edited text ✏️")
        #expect(edited.contentHash == ContentHash.of("Edited text ✏️"))
        #expect(edited.characterCount == "Edited text ✏️".count)
        #expect(edited.rtfData == nil && edited.htmlData == nil)
        #expect(edited.sortKey == before[2].sortKey)
        #expect(edited.createdAt == before[2].createdAt)
        #expect(changes == [.updated(target.id)])
        let after = t.store.ordered(5)
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after[2].plainText == "Edited text ✏️")
        #expect(t.store.search(ClipQuery(text: "edited"), offset: 0, limit: 5).map(\.id) == [target.id])

        // The old text is free again; the new text bumps the edited clip.
        let oldText = target.plainText!
        let fresh = t.text(oldText, at: now)
        #expect(fresh.id != target.id)
        #expect(t.store.count == 6)
        #expect(t.text("Edited text ✏️", at: now).id == target.id)

        if let s = t.sqlite {
            let reopened = try SQLiteClipStore(directory: s.files.root)
            let row = reopened.ordered(10).first { $0.id == target.id }
            #expect(row?.plainText == "Edited text ✏️")
            #expect(row?.rtfData == nil)
        }
    }

    @Test(arguments: StoreKind.allCases) func updateTextMergesIntoTheClipWithThatText(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        for i in (0..<6).reversed() { t.text("clip \(i)", at: ago(minutes: Double(i))) }
        let before = t.store.ordered(6)
        let edited = before[1], other = before[4]
        var changes: [ClipStoreChange] = []
        _ = t.store.addObserver { changes.append($0) }
        let result = try #require(t.store.updateText(id: edited.id, newText: other.plainText!))
        #expect(result.id == other.id)
        #expect(result.sortKey == edited.sortKey)
        #expect(result.createdAt == max(edited.createdAt, other.createdAt))
        #expect(t.store.count == 5)
        var expected = before.map(\.id)
        expected[1] = other.id
        expected.remove(at: 4)
        #expect(t.store.ordered(6).map(\.id) == expected)
        #expect(changes == [.removed(edited.id), .updated(other.id)])
        // Same text again: nothing changes.
        #expect(t.store.updateText(id: other.id, newText: other.plainText!)?.id == other.id)
        #expect(changes.count == 2)
    }

    @Test(arguments: StoreKind.allCases) func updateTextRefusesImagesEmptyTextAndUnknownClips(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        let text = t.text("hello", at: now)
        let img = try t.image(gray: 0.5, at: now)
        #expect(t.store.updateText(id: img.id, newText: "x") == nil)
        #expect(t.store.updateText(id: text.id, newText: "") == nil)
        #expect(t.store.updateText(id: UUID(), newText: "x") == nil)
        #expect(t.panelTexts() == ["<image>", "hello"])
    }

    @Test func sqliteMergePastTheCacheKeepsTheCacheInOrder() throws {
        let t = try StoreUnderTest(.sqlite)
        defer { t.remove() }
        for i in (0..<230).reversed() { t.text("clip \(i)", at: ago(minutes: Double(i))) }
        let all = t.store.ordered(230)
        // Inside the cache into past it, and past it into inside it.
        for (from, into) in [(10, 220), (225, 5)] {
            let ids = t.store.ordered(1000)
            let edited = ids.first { $0.plainText == "clip \(from)" }!
            let other = ids.first { $0.plainText == "clip \(into)" }!
            t.store.updateText(id: edited.id, newText: other.plainText!)
            var expected = ids.map(\.id)
            let old = expected.firstIndex(of: other.id)!
            expected[expected.firstIndex(of: edited.id)!] = other.id
            expected.remove(at: old)
            #expect(t.store.ordered(1000).map(\.id) == expected)
            #expect(t.store.ordered(200).map(\.id) == Array(expected.prefix(200)))
        }
        #expect(t.store.count == all.count - 2)
    }

    // MARK: Auto-clear

    @Test(arguments: StoreKind.allCases) func maxAgeRemovesClipsNotCopiedRecently(kind: StoreKind) throws {
        let t = try StoreUnderTest(kind)
        defer { t.remove() }
        let oldImage = try t.image(gray: 0.2, at: ago(days: 45))
        t.text("forty days", at: ago(days: 40))
        t.text("bumped", at: ago(days: 50))
        t.text("ten days", at: ago(days: 10))
        t.text("today", at: now)
        // Copying it again refreshes its date, so it survives.
        t.text("bumped", at: now)
        var changes: [ClipStoreChange] = []
        _ = t.store.addObserver { changes.append($0) }
        #expect(t.store.maxAge == nil)
        t.store.maxAge = 30 * 86_400
        #expect(Set(t.panelTexts()) == ["bumped", "today", "ten days"])
        #expect(changes.count == 2)
        if t.sqlite != nil {
            #expect(!t.exists(oldImage.imageURL))
            #expect(!t.exists(oldImage.thumbnailURL))
        }
        // Tightening runs at once; nil turns it off and keeps what is left.
        t.store.maxAge = 7 * 86_400
        #expect(Set(t.panelTexts()) == ["bumped", "today"])
        t.store.maxAge = nil
        t.text("old again", at: ago(days: 400))
        #expect(t.store.count == 3)
    }

    @Test func maxAgeRunsAtLaunchAlongsideTheCaps() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let now = Date()
        do {
            let store = try SQLiteClipStore(directory: dir.url)
            for i in 0..<6 { store.insertOrBump(.text("recent \(i)", at: now.addingTimeInterval(-Double(i) * 60))) }
            for i in 0..<3 { store.insertOrBump(.text("old \(i)", at: now.addingTimeInterval(-Double(40 + i) * 86_400))) }
            #expect(store.count == 9)
        }
        let reopened = try SQLiteClipStore(directory: dir.url, maxClips: 4, maxAge: 30 * 86_400)
        #expect(reopened.count == 4)
        #expect(reopened.newestByDate(10).map(\.plainText) == ["recent 0", "recent 1", "recent 2", "recent 3"])
        #expect(reopened.maxAge == TimeInterval(30 * 86_400))
    }

    @Test func retentionTimerTicksUntilToldToStop() async throws {
        let timer = RetentionTimer()
        var ticks = 0
        timer.start(every: .milliseconds(5)) {
            ticks += 1
            return ticks < 3
        }
        #expect(timer.isRunning)
        for _ in 0..<200 where ticks < 3 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(ticks == 3)
        timer.stop()
        #expect(!timer.isRunning)
    }
}

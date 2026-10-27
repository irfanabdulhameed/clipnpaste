import Testing
import Foundation
import AppKit
@testable import ClipnpasteCore

@MainActor @Suite struct PasteboardWatcherTests {
    let safari = SourceApp(bundleID: "com.apple.Safari", name: "Safari")

    func watcher(_ store: SQLiteClipStore, _ pb: FakePasteboard) -> PasteboardWatcher {
        PasteboardWatcher(
            store: store, files: store.files, pasteboard: pb,
            rules: CaptureRules(ownBundleID: "com.irfanabdulhameed.clipnpaste"),
            frontmost: { [safari] in safari }
        )
    }

    /// The app's wiring, against a temporary folder instead of the default one.
    @Test func appWiring() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        let watcher = PasteboardWatcher(store: store)
        watcher.start()
        watcher.stop()
        #expect(watcher.files == store.files)
    }

    @Test func capturesACopyWithItsSourceApp() async throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        let pb = FakePasteboard()
        let w = watcher(store, pb)
        var seen: [Clip] = []
        w.onClip = { seen.append($0) }
        #expect(w.poll() == nil)
        pb.copy(text: "copied")
        await w.poll()?.value
        #expect(store.count == 1)
        let clip = try #require(store.ordered(1).first)
        #expect(clip.plainText == "copied" && clip.sourceBundleID == "com.apple.Safari" && clip.sourceAppName == "Safari")
        #expect(seen == [clip])
        // No change, no read.
        #expect(w.poll() == nil)
    }

    @Test func ownWritesAreNotCaptured() async throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        let pb = FakePasteboard()
        let w = watcher(store, pb)
        pb.copy(text: "pasted by us")
        w.markOwnWrite(changeCount: pb.changeCount)
        #expect(w.poll() == nil)
        pb.copy(text: "next copy")
        await w.poll()?.value
        #expect(store.ordered(10).map(\.plainText) == ["next copy"])
    }

    @Test func capturesAreStoredInCopyOrder() async throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        let pb = FakePasteboard()
        let w = watcher(store, pb)
        pb.copy(data: [PasteboardTypes.tiff: TestImages.tiff(width: 900, height: 600)])
        let first = w.poll()
        pb.copy(text: "after the image")
        await w.poll()?.value
        await first?.value
        #expect(store.ordered(2).map(\.kind) == [.text, .image])
    }

    @Test func imageFilesExistBeforeTheClipIsInserted() async throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        let pb = FakePasteboard()
        let w = watcher(store, pb)
        var filesAtInsert: [Bool] = []
        _ = store.addObserver { change in
            guard case .inserted(let id) = change, let clip = store.ordered(1).first, clip.id == id else { return }
            let fm = FileManager.default
            filesAtInsert = [clip.imageURL, clip.thumbnailURL].map { $0.map { fm.fileExists(atPath: $0.path) } ?? false }
        }
        pb.copy(data: [PasteboardTypes.png: TestImages.png(width: 1200, height: 800, transparentLeft: true)])
        await w.poll()?.value
        #expect(filesAtInsert == [true, true])
        let clip = try #require(store.ordered(1).first)
        #expect(clip.kind == .image && clip.pixelWidth == 1200 && clip.pixelHeight == 800)
        #expect(clip.imageURL?.deletingLastPathComponent().lastPathComponent == "images")
        #expect(clip.thumbnailURL?.deletingLastPathComponent().lastPathComponent == "thumbs")
        // Copying the same image again bumps it instead of adding a second clip.
        pb.copy(data: [PasteboardTypes.png: TestImages.png(width: 1200, height: 800, transparentLeft: true)])
        await w.poll()?.value
        #expect(store.count == 1)
    }

    @Test func systemPasteboardAdapter() throws {
        let dir = TempDir()
        defer { dir.remove() }
        // A private pasteboard, so the real clipboard is never touched.
        let ns = NSPasteboard(name: .init("clipnpaste-test-\(UUID().uuidString)"))
        defer { ns.releaseGlobally() }
        let pb = SystemPasteboard(ns)
        let rules = CaptureRules(ownBundleID: "com.irfanabdulhameed.clipnpaste")

        let start = pb.changeCount
        ns.clearContents()
        ns.setString("plain", forType: .string)
        ns.setData(Data("{\\rtf1 plain}".utf8), forType: .rtf)
        ns.setString("com.apple.TextEdit", forType: .init(PasteboardTypes.source))
        #expect(pb.changeCount > start)
        #expect(rules.read(pb, frontmost: safari) == .capture(
            .text("plain", rtf: Data("{\\rtf1 plain}".utf8), html: nil),
            source: SourceApp(bundleID: "com.apple.TextEdit", name: nil)
        ))

        let file = dir.url.appending(path: "photo.png")
        try TestImages.png(width: 8, height: 8).write(to: file)
        ns.clearContents()
        ns.writeObjects([file as NSURL])
        #expect(pb.fileURLs().map(\.standardizedFileURL) == [file.standardizedFileURL])
        guard case .capture(.imageFile(let url), _) = rules.read(pb, frontmost: safari) else {
            Issue.record("Finder-style copy was not read as an image file")
            return
        }
        #expect(url.standardizedFileURL == file.standardizedFileURL)
    }

    @Test func skippedCopiesAreRememberedNotRetried() async throws {
        let dir = TempDir()
        defer { dir.remove() }
        let store = try SQLiteClipStore(directory: dir.url)
        let pb = FakePasteboard()
        let w = watcher(store, pb)
        pb.copy(strings: [PasteboardTypes.plainText: "secret", PasteboardTypes.concealed: ""])
        #expect(w.poll() == nil)
        #expect(w.poll() == nil)
        #expect(store.count == 0)
    }
}

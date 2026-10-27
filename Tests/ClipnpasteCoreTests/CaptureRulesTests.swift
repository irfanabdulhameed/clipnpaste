import Testing
import Foundation
@testable import ClipnpasteCore

@MainActor @Suite struct CaptureRulesTests {
    let rules = CaptureRules(ownBundleID: "com.irfanabdulhameed.clipnpaste")
    let notes = SourceApp(bundleID: "com.apple.Notes", name: "Notes")
    let png = TestImages.png(width: 4, height: 4)

    func read(_ pb: FakePasteboard, frontmost: SourceApp? = nil) -> CaptureResult {
        rules.read(pb, frontmost: frontmost ?? notes)
    }

    // MARK: Type priority and read order

    @Test func plainText() {
        let pb = FakePasteboard()
        pb.copy(text: "hello")
        #expect(read(pb) == .capture(.text("hello", rtf: nil, html: nil), source: notes))
    }

    @Test func richTextKeepsItsVersions() {
        let pb = FakePasteboard()
        let rtf = Data("{\\rtf1 hi}".utf8), html = Data("<b>hi</b>".utf8)
        pb.copy(strings: [PasteboardTypes.plainText: "hi"], data: [PasteboardTypes.rtf: rtf, PasteboardTypes.html: html])
        #expect(read(pb) == .capture(.text("hi", rtf: rtf, html: html), source: notes))
    }

    @Test func textBeatsBundledPicture() {
        let pb = FakePasteboard()
        pb.copy(strings: [PasteboardTypes.plainText: "alt text"], data: [PasteboardTypes.tiff: png])
        #expect(read(pb) == .capture(.text("alt text", rtf: nil, html: nil), source: notes))
    }

    @Test func spreadsheetCopyIsText() {
        let pb = FakePasteboard()
        let rtf = Data("{\\rtf1 a}".utf8), html = Data("<table></table>".utf8)
        pb.copy(strings: [PasteboardTypes.plainText: "Q1\t120\nQ2\t150"],
                data: [PasteboardTypes.rtf: rtf, PasteboardTypes.html: html, PasteboardTypes.png: png])
        #expect(read(pb) == .capture(.text("Q1\t120\nQ2\t150", rtf: rtf, html: html), source: notes))
    }

    @Test func browserCopyImageIsImage() {
        let pb = FakePasteboard()
        pb.copy(strings: [PasteboardTypes.plainText: "https://example.com/cat.png"], data: [PasteboardTypes.png: png])
        #expect(read(pb) == .capture(.imageData(png, type: PasteboardTypes.png), source: notes))
        pb.copy(strings: [PasteboardTypes.plainText: "/Users/me/cat.png"], data: [PasteboardTypes.png: png])
        #expect(read(pb) == .capture(.imageData(png, type: PasteboardTypes.png), source: notes))
    }

    @Test func imageWithBlankTextIsImage() {
        let pb = FakePasteboard()
        pb.copy(strings: [PasteboardTypes.plainText: " \n"], data: [PasteboardTypes.png: png])
        #expect(read(pb) == .capture(.imageData(png, type: PasteboardTypes.png), source: notes))
    }

    @Test func imageTypePriority() {
        let pb = FakePasteboard()
        let order = PasteboardTypes.images
        #expect(order == [PasteboardTypes.png, PasteboardTypes.tiff, PasteboardTypes.heic, PasteboardTypes.jpeg])
        // With every image type present, each one wins over all those after it.
        for (i, winner) in order.enumerated() {
            var data: [String: Data] = [:]
            for type in order[i...] { data[type] = Data(type.utf8) }
            pb.copy(data: data)
            #expect(read(pb) == .capture(.imageData(Data(winner.utf8), type: winner), source: notes))
        }
    }

    @Test func finderImageFileIsImage() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let file = dir.url.appending(path: "photo.png")
        try png.write(to: file)
        let pb = FakePasteboard()
        let icon = TestImages.tiff(width: 2, height: 2)
        pb.copy(strings: [PasteboardTypes.plainText: "photo.png"], data: [PasteboardTypes.tiff: icon], urls: [file])
        #expect(read(pb) == .capture(.imageFile(file), source: notes))
    }

    @Test func otherFilesAreSkipped() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let file = dir.url.appending(path: "notes.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        let pb = FakePasteboard()
        pb.copy(strings: [PasteboardTypes.plainText: "notes.pdf"], data: [PasteboardTypes.tiff: png], urls: [file])
        #expect(read(pb) == .skip(.notAnImage))
        pb.copy(strings: [PasteboardTypes.plainText: "folder"], urls: [dir.url])
        #expect(read(pb) == .skip(.notAnImage))
    }

    // MARK: Skip rules

    @Test(arguments: PasteboardTypes.skipMarkers)
    func markersAreSkipped(marker: String) {
        let pb = FakePasteboard()
        pb.copy(strings: [PasteboardTypes.plainText: "secret", marker: ""])
        #expect(read(pb) == .skip(.marker(marker)))
    }

    @Test func markerBeatsImageAndFile() {
        let pb = FakePasteboard()
        pb.copy(data: [PasteboardTypes.png: png, PasteboardTypes.concealed: Data()], urls: [URL(fileURLWithPath: "/tmp/x.png")])
        #expect(read(pb) == .skip(.marker(PasteboardTypes.concealed)))
    }

    @Test(arguments: ["com.1password.1password", "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords"])
    func passwordManagersAreSkipped(bundleID: String) {
        let pb = FakePasteboard()
        pb.copy(text: "hunter2")
        #expect(read(pb, frontmost: SourceApp(bundleID: bundleID, name: nil)) == .skip(.ignoredApp(bundleID.lowercased())))
        // Also when the app names itself with the source marker.
        pb.copy(strings: [PasteboardTypes.plainText: "hunter2", PasteboardTypes.source: bundleID])
        #expect(read(pb) == .skip(.ignoredApp(bundleID.lowercased())))
    }

    @Test func ownWritesAreSkipped() {
        let pb = FakePasteboard()
        pb.copy(strings: [PasteboardTypes.plainText: "pasted", PasteboardTypes.source: "com.irfanabdulhameed.clipnpaste"])
        #expect(read(pb) == .skip(.ownWrite))
    }

    @Test func blankAndEmptyAreSkipped() {
        let pb = FakePasteboard()
        pb.copy(text: "  \n\t ")
        #expect(read(pb) == .skip(.blank))
        pb.copy(text: "")
        #expect(read(pb) == .skip(.blank))
        pb.copy()
        #expect(read(pb) == .skip(.empty))
        pb.copy(data: ["com.example.private": Data([1])])
        #expect(read(pb) == .skip(.unsupported))
    }

    @Test func oversizedCopiesAreSkipped() {
        let pb = FakePasteboard()
        pb.copy(text: String(repeating: "a", count: CaptureRules.maxTextBytes + 1))
        #expect(read(pb) == .skip(.tooLarge))
        pb.copy(data: [PasteboardTypes.png: Data(count: CaptureRules.maxImageBytes + 1)])
        #expect(read(pb) == .skip(.tooLarge))
    }

    // MARK: Source app

    @Test func sourceMarkerBeatsFrontmostApp() {
        let pb = FakePasteboard()
        pb.copy(strings: [PasteboardTypes.plainText: "x", PasteboardTypes.source: "com.apple.Safari"])
        #expect(read(pb) == .capture(.text("x", rtf: nil, html: nil), source: SourceApp(bundleID: "com.apple.Safari", name: nil)))
    }

    @Test func universalClipboardIsCaptured() {
        let pb = FakePasteboard()
        pb.copy(strings: [PasteboardTypes.plainText: "from iPhone", PasteboardTypes.remote: ""])
        // Captured; the frontmost app did not make it, and a password manager in front does not block it.
        let onePassword = SourceApp(bundleID: "com.1password.1password", name: "1Password")
        #expect(read(pb, frontmost: onePassword) == .capture(.text("from iPhone", rtf: nil, html: nil), source: nil))
    }

    @Test func universalClipboardCanBeSwitchedOff() {
        let pb = FakePasteboard()
        pb.copy(strings: [PasteboardTypes.plainText: "from iPhone", PasteboardTypes.remote: ""])
        var off = rules
        off.captureUniversalClipboard = false
        #expect(off.read(pb, frontmost: notes) == .skip(.universalClipboard))
        // A copy made on this Mac is still kept.
        pb.copy(text: "from this Mac")
        #expect(off.read(pb, frontmost: notes) == .capture(.text("from this Mac", rtf: nil, html: nil), source: notes))
    }

    // MARK: Building clips

    @Test func textClipHashesThePlainText() throws {
        let clip = try ClipBuilder.make(
            .text("hello", rtf: Data("{\\rtf1 hello}".utf8), html: nil), source: notes, date: Date(), files: ClipFiles(root: URL(fileURLWithPath: "/nonexistent"))
        )
        #expect(clip.contentHash == DemoClips.hash("hello"))
        #expect(clip.contentHash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(clip.kind == .text && clip.characterCount == 5 && clip.sourceAppName == "Notes")
    }

    @Test func tiffIsStoredAsPNG() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let files = ClipFiles(root: dir.url)
        let clip = try ClipBuilder.make(.imageData(TestImages.tiff(width: 30, height: 20), type: PasteboardTypes.tiff), source: nil, date: Date(), files: files)
        let stored = try Data(contentsOf: try #require(clip.imageURL))
        #expect(stored.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(clip.contentHash == ContentHash.of(stored))
        #expect(clip.imageURL == files.imageURL(hash: clip.contentHash))
        #expect(FileManager.default.fileExists(atPath: try #require(clip.thumbnailURL).path))
        #expect(clip.pixelWidth == 30 && clip.pixelHeight == 20 && clip.kind == .image)
    }

    @Test func pngIsKeptByteForByte() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let clip = try ClipBuilder.make(.imageData(png, type: PasteboardTypes.png), source: nil, date: Date(), files: ClipFiles(root: dir.url))
        #expect(try Data(contentsOf: try #require(clip.imageURL)) == png)
        #expect(clip.contentHash == ContentHash.of(png))
    }

    @Test func imageFileIsReadFromDisk() throws {
        let dir = TempDir()
        defer { dir.remove() }
        let file = dir.url.appending(path: "shot.png")
        let big = TestImages.png(width: 64, height: 48)
        try big.write(to: file)
        let clip = try ClipBuilder.make(.imageFile(file), source: nil, date: Date(), files: ClipFiles(root: dir.url.appending(path: "store")))
        #expect(clip.contentHash == ContentHash.of(big))
        #expect(clip.pixelWidth == 64 && clip.pixelHeight == 48)
    }

    @Test func undecodableImageFails() {
        let dir = TempDir()
        defer { dir.remove() }
        #expect(throws: (any Error).self) {
            try ClipBuilder.make(.imageData(Data("not an image".utf8), type: PasteboardTypes.png), source: nil, date: Date(), files: ClipFiles(root: dir.url))
        }
    }
}

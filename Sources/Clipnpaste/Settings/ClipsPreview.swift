import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ClipnpasteCore

/// `--settings-preview overview|clips|check` with a demo flag (`--demo-extra` or `--empty`):
/// shows one Settings section in a plain window with ~300 generated clips (`--preview-count N`),
/// for screenshots, or (`check`) drives both sections against a temporary SQLite store and exits.
/// Never touches the real history or the clipboard. `--preview-state a,b` sets visual states:
/// selected, hover, pressed, copied, search, noresults, images, edit, confirm, loading, nogrant,
/// granted.
@MainActor
enum ClipsPreview {
    private static let args = ProcessInfo.processInfo.arguments
    static let section: String? = value(after: "--settings-preview")
    private static let states = Set((value(after: "--preview-state") ?? "").split(separator: ",").map(String.init))
    private static let count = value(after: "--preview-count").flatMap { Int($0) } ?? 300
    private static var windows: [NSWindow] = []

    private static func value(after flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    private static func say(_ s: String) {
        FileHandle.standardError.write(Data("[Clipnpaste] \(s)\n".utf8))
    }

    static func showIfAsked(env: AppEnvironment) {
        guard let section else { return }
        guard DebugFlags.usesDemoStore else {
            say("--settings-preview needs --demo-extra or --empty, so the real history is never opened")
            return
        }
        if section == "check" {
            Task { await ClipsSelfCheck.run() }
            return
        }
        if !DebugFlags.empty { ClipsDemoData.add(count, to: env.store) }
        let root: AnyView
        switch section {
        case "clips":
            let model = ClipsModel(store: env.store, watcher: env.watcher)
            model.copyInterceptor = { say("copy intercepted: \($0.id)") }
            if states.contains("loading") { model.holdLoading = true } else { applyStates(to: model) }
            root = AnyView(ClipsSection(env: env, model: model))
        default:
            let model = OverviewModel(store: env.store)
            if states.contains("nogrant") { model.permissionOverride = false }
            if states.contains("granted") { model.permissionOverride = true }
            if states.contains("confirm") { model.confirmingClear = true }
            if states.contains("autoclear") { env.store.maxAge = 30 * 86_400 }
            root = AnyView(OverviewSection(env: env, model: model))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = section == "clips" ? "Clips" : "Overview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.minX + 40, y: f.minY + 40))
        }
        // Behind other windows and never key, so nothing takes the keyboard from the app in use.
        window.orderBack(nil)
        windows.append(window)
        say("preview window \(window.windowNumber)")
        Task {
            // The copy checkmark lasts 1.5 s, so that state is captured early.
            try? await Task.sleep(for: .seconds(states.contains("copied") ? 0.5 : 1.5))
            for w in NSApp.windows where w.sheetParent === window || (w !== window && w.isVisible && w.parent === window) {
                say("preview sheet \(w.windowNumber)")
            }
            say("preview ready")
        }
    }

    /// Sets visual states on the model so one screenshot shows them.
    private static func applyStates(to model: ClipsModel) {
        model.start()
        if states.contains("search") { model.query = "git" }
        if states.contains("noresults") { model.query = "quarterly forecast" }
        if states.contains("images") { model.filter = .images }
        model.columns = 3
        let ids = model.clips.map(\.id)
        if states.contains("selected"), ids.count > 5 {
            model.click(ids[1], command: false, shift: false)
            model.click(ids[2], command: true, shift: false)
            model.click(ids[4], command: true, shift: false)
            model.forceFocused = true
        }
        if states.contains("single"), ids.count > 1 {
            model.click(ids[1], command: false, shift: false)
            model.forceFocused = true
        }
        if states.contains("hover"), ids.count > 0 { model.hover(ids[0], button: .copy) }
        if states.contains("pressed"), ids.count > 3 { model.pressDown(ids[3], button: nil, command: false, shift: false) }
        if states.contains("copied"), let first = model.clips.first(where: { $0.kind == .text }) {
            model.hover(first.id, button: .copy)
            model.copy(first.id)
        }
        if states.contains("edit"), let first = model.clips.first(where: { $0.kind == .text && ($0.plainText?.count ?? 0) > 60 }) {
            model.open(first.id)
        }
        if states.contains("confirm") { model.confirmingClear = true }
    }
}

/// About 300 believable clips from a dozen apps over five weeks, newest first, placed behind
/// the demo clips so the first screen keeps the demo's images.
@MainActor
enum ClipsDemoData {
    static let apps: [(String, String)] = [
        ("com.apple.Safari", "Safari"), ("com.apple.mail", "Mail"), ("com.apple.dt.Xcode", "Xcode"),
        ("com.apple.Terminal", "Terminal"), ("com.apple.Notes", "Notes"), ("com.apple.MobileSMS", "Messages"),
        ("com.figma.Desktop", "Figma"), ("com.apple.Maps", "Maps"), ("com.apple.finder", "Finder"),
        ("com.apple.TextEdit", "TextEdit"),
    ]

    /// The text of clip `i`; every one is different.
    static func text(_ i: Int) -> (String, Int) {
        let n = i + 1
        switch i % 12 {
        case 0: return ("https://github.com/irfanabdulhameed/clipnpaste/pull/\(40 + n)", 0)
        case 1: return ("Invoice 2026-\(118 + n) sent to Arjun, due on the \(n % 28 + 1)th.", 1)
        case 2: return ("let columns\(n) = Array(repeating: GridItem(.fixed(\(180 + n % 60))), count: \(n % 4 + 2))", 2)
        case 3: return ("git log --oneline -n \(n) --since=\"\(n % 9 + 1) days ago\" -- Sources/Clipnpaste/Settings", 3)
        case 4: return ("Groceries: oat milk, \(n % 6 + 2) lemons, basmati rice, coriander, ginger. Week \(n / 12 + 1).", 4)
        case 5: return ("Running \(n % 15 + 3) minutes late for call \(n), start without me 🙏", 5)
        case 6: return (String(format: "#%06X", (n * 2_654_435 + 0x1F6FEB) & 0xFFFFFF), 6)
        case 7: return ("\(n) Residency Road, Bengaluru 5600\(n % 90 + 10)", 7)
        case 8: return ("/Users/irfan/Documents/Renders/shot_\(String(format: "%03d", n)).mov", 8)
        case 9: return ("Draft \(n): The opening shot holds too long before the first move. Trim eight frames from the head and let the panel arrive while the music is still rising, then keep the stagger tight.", 9)
        case 10: return ("swift test --filter ClipStoreQueriesTests/case\(n)", 3)
        default: return ("Can we move the review to Thursday at \(n % 5 + 2):30? I'll bring revision \(n).", 1)
        }
    }

    static func clips(_ count: Int, now: Date = Date()) -> [Clip] {
        (0..<count).map { i in
            let (s, a) = text(i)
            let app = apps[a]
            // Denser today, thinning out over about five weeks.
            let minutes = 60 + Double(i * i) * 0.6
            return Clip(kind: .text, plainText: s, sourceBundleID: app.0, sourceAppName: app.1,
                        createdAt: now.addingTimeInterval(-minutes * 60), contentHash: ContentHash.of(s))
        }
    }

    static func add(_ count: Int, to store: any ClipStore) {
        for clip in clips(count) {
            let stored = store.insertOrBump(clip)
            store.move(id: stored.id, toIndex: store.count - 1)
        }
    }

    /// A gradient PNG of the given size, written into the store's own images folder.
    static func image(_ w: Int, _ h: Int, hue: CGFloat, files: ClipFiles, at date: Date, app: (String, String)) -> Clip? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let a = NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor
        let b = NSColor(hue: hue + 0.12, saturation: 0.7, brightness: 0.45, alpha: 1).cgColor
        if let g = CGGradient(colorsSpace: space, colors: [a, b] as CFArray, locations: nil) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        guard let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let data = out as Data
        let hash = ContentHash.of(data)
        let url = files.imageURL(hash: hash)
        try? files.createDirectories()
        guard (try? data.write(to: url)) != nil else { return nil }
        return Clip(kind: .image, imageURL: url, pixelWidth: w, pixelHeight: h, sourceBundleID: app.0,
                    sourceAppName: app.1, createdAt: date, contentHash: hash)
    }
}

/// `--settings-preview check`: both sections' models against a temporary SQLite store, then exit
/// 0 when every check passed. Copies are intercepted, so the clipboard is never written.
@MainActor
enum ClipsSelfCheck {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = ok ? "" : " — \(detail())"
        FileHandle.standardError.write(Data("[check] \(ok ? "PASS" : "FAIL") \(name)\(d)\n".utf8))
    }

    static func run() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "clipnpaste-settings-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        await checks(in: dir)
        // `exit` skips `defer`, so the temporary store goes first.
        try? FileManager.default.removeItem(at: dir)
        finish()
    }

    private static func checks(in dir: URL) async {
        let store: SQLiteClipStore
        do { store = try SQLiteClipStore(directory: dir) } catch {
            check("open a temporary store", false, "\(error)")
            return
        }
        let now = Date()
        // Images first, so they sit behind the text clips in panel order.
        var images: [Clip] = []
        for (i, size) in [(1920, 1080), (600, 600), (1170, 2532), (800, 600)].enumerated() {
            if let c = ClipsDemoData.image(size.0, size.1, hue: CGFloat(i) * 0.2, files: store.files,
                                           at: now.addingTimeInterval(-Double(i) * 30), app: ("com.apple.Photos", "Photos")) {
                images.append(store.insertOrBump(c))
            }
        }
        for clip in ClipsDemoData.clips(300, now: now).reversed() { store.insertOrBump(clip) }
        check("store holds 304 clips", store.count == 304, "\(store.count)")
        let missing = images[3]
        try? FileManager.default.removeItem(at: missing.imageURL!)

        let env = AppEnvironment(store: store, watcher: NoOpWatcher())
        var copied: [UUID] = []
        var revealed: [URL] = []
        let model = ClipsModel(store: env.store, watcher: env.watcher)
        model.copyInterceptor = { copied.append($0.id) }
        model.revealInterceptor = { revealed.append($0) }
        model.columns = 3
        model.start()

        // Paging
        check("first page", model.clips.count == ClipsModel.pageSize && model.matchCount == 304 && model.phase == .ready,
              "\(model.clips.count) of \(model.matchCount)")
        model.loadMore()
        model.loadMore()
        check("pages to the end", model.clips.count == 304 && !model.hasMore, "\(model.clips.count)")
        check("panel order", model.clips.map(\.id) == store.ordered(400).map(\.id))

        // Search and filter
        let invoices = ClipsDemoData.clips(300).filter { $0.plainText!.lowercased().contains("invoice") }.count
        model.query = "invoice"
        check("search finds every invoice", model.matchCount == invoices && model.clips.allSatisfy { $0.plainText!.lowercased().contains("invoice") },
              "\(model.matchCount) vs \(invoices)")
        model.query = "INVOICE"
        check("search ignores case", model.matchCount == invoices)
        model.query = "bengaluru 5600"
        check("search a substring", model.matchCount > 0 && model.clips.allSatisfy { $0.plainText!.contains("Bengaluru 5600") })
        model.query = "no such words anywhere"
        check("no results", model.clips.isEmpty && model.matchCount == 0 && !model.isEmptyStore)
        model.query = ""
        model.filter = .images
        check("images filter", model.matchCount == 4 && model.clips.allSatisfy { $0.kind == .image })
        model.filter = .text
        check("text filter", model.matchCount == 300 && model.clips.allSatisfy { $0.kind == .text })
        model.query = "invoice"
        model.filter = .images
        check("search with images filter", model.matchCount == 0)
        model.filter = .all
        model.query = ""
        check("back to all", model.matchCount == 304 && model.clips.count == ClipsModel.pageSize, "\(model.clips.count)")

        // Selection: click, ⌘-click, ⇧-click, ⌘A
        var ids = model.clips.map(\.id)
        model.click(ids[0], command: false, shift: false)
        check("click selects one", model.selection == [ids[0]])
        model.click(ids[3], command: true, shift: false)
        check("⌘-click adds", model.selection == [ids[0], ids[3]])
        model.click(ids[6], command: false, shift: true)
        check("⇧-click selects the run from the anchor", model.selection == Set(ids[3...6]))
        model.click(ids[4], command: true, shift: false)
        check("⌘-click removes", model.selection == Set([ids[3], ids[5], ids[6]]))
        model.click(ids[9], command: true, shift: true)
        check("⌘⇧-click adds a run", model.selection == Set([ids[3], ids[5], ids[6]]).union(ids[4...9]))
        _ = model.handleKey(KeyEquivalent("a"), modifiers: .command)
        check("⌘A selects every match", model.selection.count == 304 && model.clips.count == 304)
        _ = model.handleKey(.escape, modifiers: [])
        check("Esc clears the selection", model.selection.isEmpty)

        // Keyboard
        ids = model.clips.map(\.id)
        model.click(ids[0], command: false, shift: false)
        _ = model.handleKey(.rightArrow, modifiers: [])
        check("→ moves one card", model.selection == [ids[1]])
        _ = model.handleKey(.downArrow, modifiers: [])
        check("↓ moves one row", model.selection == [ids[4]])
        _ = model.handleKey(.rightArrow, modifiers: .shift)
        _ = model.handleKey(.rightArrow, modifiers: .shift)
        check("⇧→ extends", model.selection == Set(ids[4...6]))
        _ = model.handleKey(.upArrow, modifiers: [])
        check("↑ moves one row", model.selection == [ids[3]])
        _ = model.handleKey(.upArrow, modifiers: [])
        _ = model.handleKey(.upArrow, modifiers: [])
        check("↑ on the top row stays", model.selection == [ids[0]])
        _ = model.handleKey(.end, modifiers: [])
        check("End goes to the last", model.selection == [ids.last!])
        _ = model.handleKey(.home, modifiers: [])
        check("Home goes to the first", model.selection == [ids[0]])

        // Multi-select delete
        model.click(ids[1], command: false, shift: false)
        model.click(ids[2], command: true, shift: false)
        model.click(ids[5], command: true, shift: false)
        let handled = model.handleKey(.delete, modifiers: []).handled
        check("Delete removes the selection", handled && store.count == 301 && [ids[1], ids[2], ids[5]].allSatisfy { model.clip($0) == nil },
              "\(store.count)")
        check("selection moves to the next card", model.selection == [ids[3]], "\(model.selection)")

        // Opening an image shows it in Finder; a missing one does nothing.
        model.open(images[1].id)
        model.open(missing.id)
        check("open an image shows it in Finder", revealed == [images[1].imageURL!] && model.editing == nil)

        // An image and its file
        let img = images[0]
        model.delete([img.id])
        check("deleting an image removes its file", store.count == 300 && !FileManager.default.fileExists(atPath: img.imageURL!.path))

        // Missing file and copy
        check("a missing image can't be copied", !model.isUsable(model.clip(missing.id)!) && model.missing.contains(missing.id))
        model.copy(missing.id)
        check("no copy for a missing file", model.marks[missing.id] == nil && !copied.contains(missing.id))
        let text = model.clips.first { $0.kind == .text }!
        model.copy(text.id)
        check("copy uses the write-back path", copied == [text.id] && model.marks[text.id] == .done)

        // Edit
        let target = model.clips.first { $0.kind == .text && $0.id != text.id }!
        let slot = store.ordered(400).firstIndex { $0.id == target.id }
        model.click(target.id, command: false, shift: false)
        _ = model.handleKey(.return, modifiers: [])
        check("Return opens the editor", model.editing?.id == target.id)
        let saved = model.save(target, text: "Edited in the settings check")
        let after = store.ordered(400)
        check("save changes the text in place", saved && model.editing == nil
              && after.firstIndex(where: { $0.id == target.id }) == slot
              && after.first { $0.id == target.id }?.plainText == "Edited in the settings check")
        model.query = "edited in the settings"
        check("the edit is searchable", model.matchCount == 1 && model.selection == [target.id])
        model.query = ""
        let a = model.clips.first { $0.kind == .text && $0.id != target.id }!
        let b = model.clips.last { $0.kind == .text && $0.id != a.id && $0.id != target.id }!
        let before = store.count
        check("save to another clip's text merges", model.save(a, text: b.plainText!) && store.count == before - 1
              && model.clip(a.id) == nil && model.selection == [b.id])
        check("an empty text is refused", !model.save(b, text: ""))

        // Live updates
        store.insertOrBump(Clip(kind: .text, plainText: "Live from another app", contentHash: ContentHash.of("Live from another app")))
        try? await Task.sleep(for: .milliseconds(100))
        check("follows the store", model.totalCount == store.count && model.clips.first?.plainText == "Live from another app")

        // Overview
        let overview = OverviewModel(store: env.store)
        overview.start()
        let counts = store.countsByKind()
        check("overview counts", overview.counts == counts && counts.image == 3, "\(overview.counts)")
        check("overview today", overview.today == store.copies(onDayOf: Date()) && overview.today > 0, "\(overview.today)")
        check("overview top apps", (1...5).contains(overview.topApps.count) && overview.topApps.first!.count >= overview.topApps.last!.count)
        check("overview storage", overview.imageBytes > 0 && overview.storageFraction > 0 && overview.storageFraction < 1
              && overview.imageCap == SQLiteClipStore.defaultMaxImageBytes)
        store.maxAge = 7 * 86_400
        try? await Task.sleep(for: .milliseconds(100))
        check("auto-clear removes old clips", store.newestByDate(1000).allSatisfy { $0.createdAt >= Date().addingTimeInterval(-7 * 86_400 - 5) })
        check("overview shows auto-clear", overview.maxAge == 7 * 86_400 && overview.counts.total == store.count)
        check("grid follows auto-clear", model.totalCount == store.count)

        // Clear all
        model.confirmingClear = true
        model.clearAll()
        try? await Task.sleep(for: .milliseconds(100))
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: store.files.images.path)) ?? [])
            + ((try? FileManager.default.contentsOfDirectory(atPath: store.files.thumbs.path)) ?? [])
        check("clear all empties the store and files", store.count == 0 && leftovers.isEmpty && model.isEmptyStore && model.selection.isEmpty)
        check("overview empty", overview.counts.total == 0 && overview.imageBytes == 0)
        model.stop()
        overview.stop()
    }

    private static func finish() {
        FileHandle.standardError.write(Data("[check] \(passes) passed, \(failures) failed\n".utf8))
        exit(failures == 0 ? 0 : 1)
    }
}

import AppKit

/// The real pasteboard behind `PasteboardAccess`.
@MainActor
public final class SystemPasteboard: PasteboardAccess {
    public let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public var types: Set<String> {
        var all = Set((pasteboard.types ?? []).map(\.rawValue))
        for item in pasteboard.pasteboardItems ?? [] {
            all.formUnion(item.types.map(\.rawValue))
        }
        return all
    }

    public func data(forType type: String) -> Data? {
        pasteboard.data(forType: NSPasteboard.PasteboardType(type))
    }

    public func string(forType type: String) -> String? {
        pasteboard.string(forType: NSPasteboard.PasteboardType(type))
    }

    public func fileURLs() -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }
}

/// Polls the pasteboard's change count and stores each copy the capture rules keep.
/// Captures are processed in copy order; image files and thumbnails are written off the
/// main actor before the clip is inserted.
@MainActor
public final class PasteboardWatcher: ClipboardWatcher {
    public nonisolated static let interval: TimeInterval = 0.5
    public nonisolated static let tolerance: TimeInterval = 0.1
    /// After this long with no keyboard or mouse input, the poll slows down.
    public nonisolated static let idleAfter: TimeInterval = 60
    public nonisolated static let idleInterval: TimeInterval = 1.5

    public var onClip: (@MainActor (Clip) -> Void)?
    public let store: any ClipStore
    public let files: ClipFiles
    public var rules: CaptureRules

    private let pasteboard: any PasteboardAccess
    private let frontmost: @MainActor () -> SourceApp?
    private var lastChangeCount: Int
    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var pending: Task<Void, Never>?

    /// Images go to the store's own `images/` and `thumbs/` folders.
    public convenience init(store: SQLiteClipStore) {
        self.init(store: store, files: store.files)
    }

    public init(
        store: any ClipStore,
        files: ClipFiles,
        pasteboard: (any PasteboardAccess)? = nil,
        rules: CaptureRules = CaptureRules(),
        frontmost: (@MainActor () -> SourceApp?)? = nil
    ) {
        let pasteboard = pasteboard ?? SystemPasteboard()
        self.store = store
        self.files = files
        self.rules = rules
        self.pasteboard = pasteboard
        self.frontmost = frontmost ?? PasteboardWatcher.frontmostApp
        lastChangeCount = pasteboard.changeCount
    }

    /// Starts polling. What is on the pasteboard already is not captured.
    public func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        schedule(Self.interval)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func markOwnWrite(changeCount: Int) {
        lastChangeCount = changeCount
    }

    /// Checks at once, for example when the panel opens.
    public func checkNow() {
        poll()
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            MainActor.assumeIsolated { self.tick() }
        }
        t.tolerance = interval * Self.tolerance / Self.interval
        RunLoop.main.add(t, forMode: .common)
        timer = t
        currentInterval = interval
    }

    private func tick() {
        poll()
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let want = idle >= Self.idleAfter ? Self.idleInterval : Self.interval
        if want != currentInterval { schedule(want) }
    }

    /// Reads the pasteboard if its count moved. Returns the capture's task, if any.
    @discardableResult
    func poll() -> Task<Void, Never>? {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count
        guard case let .capture(content, source) = rules.read(pasteboard, frontmost: frontmost()) else { return nil }
        return enqueue(content, source: Self.named(source), date: Date())
    }

    private func enqueue(_ content: CapturedContent, source: SourceApp?, date: Date) -> Task<Void, Never> {
        let previous = pending
        let files = files
        let task = Task { @MainActor [weak self] in
            await previous?.value
            let clip = await Task.detached(priority: .utility) {
                try? ClipBuilder.make(content, source: source, date: date, files: files)
            }.value
            guard let self, let clip else { return }
            // The store may have dropped a same-image clip and its files meanwhile.
            if let url = clip.imageURL, !FileManager.default.fileExists(atPath: url.path) { return }
            let stored = self.store.insertOrBump(clip)
            self.onClip?(stored)
        }
        pending = task
        return task
    }

    private static func frontmostApp() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return SourceApp(bundleID: app.bundleIdentifier, name: app.localizedName)
    }

    /// Fills in the app name when only the source marker's bundle id is known.
    private static func named(_ source: SourceApp?) -> SourceApp? {
        guard var source, source.name == nil, let id = source.bundleID else { return source }
        source.name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
        return source
    }
}

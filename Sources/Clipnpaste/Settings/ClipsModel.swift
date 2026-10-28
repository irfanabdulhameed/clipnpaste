import AppKit
import SwiftUI
import ClipnpasteCore

/// The Clips section's state: the search, the loaded page of matching clips, the selection, and
/// every change the section makes to the store. The views only draw it and report input.
@MainActor @Observable
final class ClipsModel {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all, text, images
        var id: Self { self }
        var title: String {
            switch self {
            case .all: "All"
            case .text: "Text"
            case .images: "Images"
            }
        }
        var kind: ClipKind? {
            switch self {
            case .all: nil
            case .text: .text
            case .images: .image
            }
        }
    }

    enum Phase: Sendable { case loading, ready }

    /// Clips are read in pages of this many as the grid scrolls.
    static let pageSize = 120
    /// The cards are the panel's cards at a 14-inch MacBook's size (200 × 123 pt, four lines).
    static let geometry = PanelGeometry(visibleWidth: 1512, visibleHeight: 945, screenHeight: 982)
    static let gap: CGFloat = 12
    static let inset: CGFloat = 20

    @ObservationIgnored let store: any ClipStore
    @ObservationIgnored let watcher: any ClipboardWatcher

    var query = "" { didSet { if query != oldValue { requery() } } }
    var filter: Filter = .all { didSet { if filter != oldValue { requery() } } }
    /// The loaded clips matching the search, in panel order.
    private(set) var clips: [Clip] = []
    /// All clips matching the search (more than `clips` while pages are left).
    private(set) var matchCount = 0
    /// All clips in the store.
    private(set) var totalCount = 0
    private(set) var phase: Phase = .loading
    var selection: Set<UUID> = []
    /// Where a ⇧-click or ⇧-arrow range starts.
    private(set) var anchor: UUID?
    /// The card the keyboard moves from: the last one clicked or reached.
    private(set) var cursor: UUID?
    private(set) var hovered: UUID?
    private(set) var hoveredButton: CardButton?
    private(set) var pressed: UUID?
    private(set) var pressedButton: CardButton?
    private(set) var marks: [UUID: CopyMark] = [:]
    private(set) var missing: Set<UUID> = []
    /// The text clip in the editor sheet.
    var editing: Clip?
    var confirmingClear = false
    var theme = ClipsModel.liveTheme()
    /// Time labels are relative to the last reload.
    private(set) var now = Date()
    var columns = 1
    /// Left and right of the grid: at least `inset`, with the leftover split so the grid is centred.
    private(set) var sidePadding = ClipsModel.inset
    /// The grid has the keyboard: the selection ring is the accent colour, else grey.
    var gridFocused = false
    /// `--settings-preview`: show the grid as focused in a window that is never key.
    @ObservationIgnored var forceFocused = false

    /// `--settings-preview check`: records a copy instead of writing the clipboard.
    @ObservationIgnored var copyInterceptor: ((Clip) -> Void)?
    /// `--settings-preview check`: records "Show in Finder" instead of opening Finder.
    @ObservationIgnored var revealInterceptor: ((URL) -> Void)?
    /// The last mouse down on a card, for double clicks.
    @ObservationIgnored private var lastDown: (id: UUID, time: CFTimeInterval)?
    @ObservationIgnored private var index: [UUID: Int] = [:]
    @ObservationIgnored private var motions: [UUID: ClipsCardMotion] = [:]
    @ObservationIgnored private var markTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var reloadQueued = false
    @ObservationIgnored private var lastSelection: CFTimeInterval = 0
    @ObservationIgnored private var openOnRelease = false

    init(store: any ClipStore, watcher: any ClipboardWatcher) {
        self.store = store
        self.watcher = watcher
    }

    var currentQuery: ClipQuery { ClipQuery(text: query, kind: filter.kind) }
    var hasMore: Bool { clips.count < matchCount }
    var isEmptyStore: Bool { phase == .ready && totalCount == 0 }
    var isSearching: Bool { !currentQuery.needle.isEmpty || filter != .all }
    var ringFocused: Bool { gridFocused || forceFocused }

    // MARK: Loading

    /// `--settings-preview loading`: stays in the first state, before the first read.
    @ObservationIgnored var holdLoading = false

    /// Starts following the store. Pair with `stop`.
    func start() {
        guard observer == nil, !holdLoading else { return }
        observer = store.addObserver { [weak self] _ in self?.queueReload() }
        theme = ClipsModel.liveTheme()
        reload()
    }

    func stop() {
        if let observer { store.removeObserver(observer) }
        observer = nil
    }

    /// Many changes in one go (a bulk delete) reload once.
    private func queueReload() {
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadQueued = false
            self.reload()
        }
    }

    /// Reads the loaded range again, keeping as many clips as were loaded.
    func reload() {
        let q = currentQuery
        totalCount = store.count
        matchCount = store.count(matching: q)
        setClips(store.search(q, offset: 0, limit: max(clips.count, Self.pageSize)))
        now = Date()
        phase = .ready
    }

    /// The search changed: back to the first page. Selected clips still in the results stay selected.
    private func requery() {
        clips = []
        reload()
    }

    func loadMore() {
        guard hasMore else { return }
        let more = store.search(currentQuery, offset: clips.count, limit: Self.pageSize)
        guard !more.isEmpty else {
            matchCount = clips.count
            return
        }
        setClips(clips + more.filter { index[$0.id] == nil })
    }

    /// Every matching clip, for ⌘A and End.
    func loadAll() {
        guard hasMore else { return }
        setClips(store.search(currentQuery, offset: 0, limit: max(matchCount, clips.count)))
        matchCount = max(matchCount, clips.count)
    }

    private func setClips(_ list: [Clip]) {
        clips = list
        index = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(index.keys)
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        if let a = anchor, !ids.contains(a) { anchor = nil }
        if let c = cursor, !ids.contains(c) { cursor = nil }
        if let h = hovered, !ids.contains(h) { hovered = nil; hoveredButton = nil }
        if let p = pressed, !ids.contains(p) { pressed = nil; pressedButton = nil }
        if !missing.isSubset(of: ids) { missing.formIntersection(ids) }
        if let e = editing, !ids.contains(e.id) { editing = nil }
    }

    func indexOf(_ id: UUID) -> Int? { index[id] }

    func clip(_ id: UUID) -> Clip? { index[id].map { clips[$0] } }

    /// Fits whole columns of cards into `width`, as the panel fits its row.
    func layout(width: CGFloat) {
        let w = CGFloat(Self.geometry.cardWidth)
        let n = max(Int((width - 2 * Self.inset + Self.gap) / (w + Self.gap)), 1)
        let grid = CGFloat(n) * w + CGFloat(n - 1) * Self.gap
        let side = max(Self.inset, ((width - grid) / 2).rounded(.down))
        if n != columns { columns = n }
        if side != sidePadding { sidePadding = side }
    }

    // MARK: What a card shows

    func state(for id: UUID) -> CardState {
        let isPressed = pressed == id
        // With several selected, only the hovered card shows its buttons.
        return CardState(
            selected: selection.count == 1 && selection.contains(id),
            hovered: hovered == id,
            hoveredButton: hovered == id ? hoveredButton : nil,
            pressed: isPressed && pressedButton == nil,
            pressedButton: isPressed ? pressedButton : nil,
            focus: nil,
            mark: marks[id],
            missing: missing.contains(id)
        )
    }

    func markMissing(_ id: UUID) {
        if !missing.contains(id) { missing.insert(id) }
    }

    func motion(for id: UUID) -> ClipsCardMotion {
        if let m = motions[id] { return m }
        let m = ClipsCardMotion()
        motions[id] = m
        return m
    }

    /// A card scrolled away: its motion goes back to rest and is let go.
    func forget(_ id: UUID) {
        motions.removeValue(forKey: id)?.rest()
    }

    // MARK: Pointer

    /// A button under the pointer pops 1.08 (the fill flip is the card's); a card hover is a flip only.
    func hover(_ id: UUID?, button: CardButton?) {
        let changed = hovered != id || hoveredButton != button
        if hovered != id { hovered = id }
        if hoveredButton != button { hoveredButton = button }
        guard changed, !Motion.reduce, let id, let button else { return }
        if button == .copy, missing.contains(id) { return }
        motion(for: id).look.anim(button).pop()
    }

    /// Mouse down. On a card: selects (⌘ toggles, ⇧ extends) and dips it to 0.97; a second press
    /// on the same card within the system's double-click interval opens it on release. On a
    /// button: dips the button to 0.92; it acts on release.
    func pressDown(_ id: UUID, button: CardButton?, command: Bool, shift: Bool) {
        setPressed(id, button)
        openOnRelease = false
        guard button == nil else {
            lastDown = nil
            return
        }
        let t = CACurrentMediaTime()
        let double = lastDown.map { $0.id == id && t - $0.time <= NSEvent.doubleClickInterval } ?? false
        lastDown = double ? nil : (id, t)
        if double, !command, !shift {
            openOnRelease = true
            return
        }
        click(id, command: command, shift: shift)
    }

    /// The pointer left (or came back to) the pressed card or button while held.
    func pressTracked(_ id: UUID, button: CardButton?, inside: Bool) {
        let want: (UUID?, CardButton?) = inside ? (id, button) : (nil, nil)
        if pressed != want.0 || pressedButton != want.1 { setPressed(want.0, want.1) }
    }

    func pressUp(_ id: UUID, button: CardButton?, inside: Bool) {
        setPressed(nil, nil)
        guard inside else { return }
        if let button {
            switch button {
            case .copy: copy(id)
            case .remove: delete([id])
            }
        } else if openOnRelease {
            openOnRelease = false
            open(id)
        }
    }

    /// Press dips in 70 ms on popUp and holds; release springs back on `quick`. Under Reduce
    /// Motion the card darkens instead (the card view draws it).
    private func setPressed(_ id: UUID?, _ button: CardButton?) {
        let old = (pressed, pressedButton)
        pressed = id
        pressedButton = button
        guard !Motion.reduce else { return }
        if let o = old.0, o != id || old.1 != button {
            let m = motion(for: o)
            if let b = old.1 { m.look.anim(b).spring(to: 1, duration: Motion.quick) } else { m.dip.spring(to: 1, duration: Motion.quick) }
        }
        if let id, old.0 != id || old.1 != button {
            let m = motion(for: id)
            if let b = button {
                m.look.anim(b).tween(to: Motion.dipControl, ms: Motion.dipMs, ease: Motion.popUp)
            } else {
                m.dip.tween(to: Motion.dipCard, ms: Motion.dipMs, ease: Motion.popUp)
            }
        }
    }

    // MARK: Selection

    /// A click: plain selects only this card, ⌘ adds or removes it, ⇧ selects the run from the anchor.
    func click(_ id: UUID, command: Bool, shift: Bool) {
        if shift {
            selection = command ? selection.union(run(anchor ?? id, id)) : run(anchor ?? cursor ?? id, id)
            if anchor == nil { anchor = id }
        } else if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            let changed = selection != [id]
            selection = [id]
            anchor = id
            if changed { popSelected(id) }
        }
        cursor = id
    }

    func selectAll() {
        loadAll()
        selection = Set(clips.map(\.id))
        if cursor == nil { cursor = clips.first?.id }
        if anchor == nil { anchor = cursor }
    }

    func clearSelection() {
        selection = []
        anchor = nil
    }

    /// Arrow keys: one card sideways or one row up or down. With ⇧ the run from the anchor grows.
    /// Returns the card to scroll to.
    @discardableResult
    func moveCursor(dx: Int, dy: Int, extend: Bool) -> UUID? {
        guard !clips.isEmpty else { return nil }
        var to: Int
        if let c = cursor.flatMap(indexOf) {
            to = c + dx + dy * max(columns, 1)
            if to < 0 { to = dy < 0 ? c : 0 }
            if to >= clips.count, hasMore { loadMore() }
            to = min(to, clips.count - 1)
        } else {
            to = 0
        }
        return moveCursor(toIndex: to, extend: extend)
    }

    @discardableResult
    func moveCursor(toIndex i: Int, extend: Bool) -> UUID? {
        guard !clips.isEmpty else { return nil }
        let id = clips[min(max(i, 0), clips.count - 1)].id
        if extend {
            selection = run(anchor ?? cursor ?? id, id)
            if anchor == nil { anchor = cursor ?? id }
        } else {
            let changed = selection != [id]
            selection = [id]
            anchor = id
            if changed { popSelected(id) }
        }
        cursor = id
        return id
    }

    private func run(_ a: UUID, _ b: UUID) -> Set<UUID> {
        guard let i = indexOf(a), let j = indexOf(b) else { return [b] }
        return Set(clips[min(i, j)...max(i, j)].map(\.id))
    }

    /// The newly selected card pops 1.08, unless the last change was under 120 ms ago (a held
    /// arrow key), as in the panel. Under Reduce Motion nothing pops.
    private func popSelected(_ id: UUID) {
        let t = CACurrentMediaTime()
        let held = (t - lastSelection) * 1000 < Motion.repeatMs
        lastSelection = t
        guard !Motion.reduce, !held else { return }
        motion(for: id).pop.pop()
    }

    // MARK: Actions

    /// Return or a double click: a text clip opens in the editor, an image shows in Finder.
    func open(_ id: UUID) {
        guard let clip = clip(id) else { return }
        switch clip.kind {
        case .text: editing = clip
        case .image: revealInFinder(id)
        }
    }

    func revealInFinder(_ id: UUID) {
        guard let clip = clip(id), let url = clip.imageURL, isUsable(clip) else { return }
        if let intercept = revealInterceptor { return intercept(url) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// An image whose file has gone can't be copied or shown; it can only be deleted.
    func isUsable(_ clip: Clip) -> Bool {
        if missing.contains(clip.id) { return false }
        guard clip.kind == .image else { return true }
        if let url = clip.imageURL, FileManager.default.fileExists(atPath: url.path) { return true }
        markMissing(clip.id)
        return false
    }

    /// Copies through the panel's write-back path (marked as our own write, so it is not captured
    /// again). The button hard-cuts to a checkmark inside a 1.08 pop and back after 1.5 s.
    func copy(_ id: UUID) {
        guard let clip = clip(id), isUsable(clip) else { return }
        if let intercept = copyInterceptor {
            intercept(clip)
            marks[id] = .done
        } else if let count = Paster.write(clip) {
            watcher.markOwnWrite(changeCount: count)
            marks[id] = .done
        } else {
            marks[id] = .failed
        }
        if !Motion.reduce { motion(for: id).look.copy.pop() }
        let token = UUID()
        markTokens[id] = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.markTokens[id] == token else { return }
            self.markTokens[id] = nil
            self.marks[id] = nil
        }
    }

    /// The copy for ⌘C and the context menu: the only selected clip.
    var singleSelection: Clip? { selection.count == 1 ? selection.first.flatMap(clip) : nil }

    /// Deletes the clips. If any was selected, the selection moves to the card that took the
    /// first one's place, as in the panel.
    func delete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let first = ids.compactMap(indexOf).min()
        let hadSelection = !selection.isDisjoint(with: ids)
        store.remove(ids: ids)
        for id in ids {
            marks[id] = nil
            markTokens[id] = nil
            forget(id)
        }
        reload()
        guard hadSelection else { return }
        selection.subtract(ids)
        if selection.isEmpty, let first, !clips.isEmpty {
            let id = clips[min(first, clips.count - 1)].id
            selection = [id]
            anchor = id
            cursor = id
        }
    }

    func deleteSelected() {
        let ids = clips.map(\.id).filter(selection.contains)
        delete(ids)
    }

    /// Saves the editor's text. Returns false when the store refused it.
    func save(_ clip: Clip, text: String) -> Bool {
        if text == clip.plainText {
            editing = nil
            return true
        }
        guard let result = store.updateText(id: clip.id, newText: text) else { return false }
        reload()
        editing = nil
        if index[result.id] != nil {
            selection = [result.id]
            anchor = result.id
            cursor = result.id
        }
        return true
    }

    func clearAll() {
        store.removeAll()
        selection = []
        anchor = nil
        cursor = nil
        marks = [:]
        markTokens = [:]
        missing = []
        for id in Array(motions.keys) { forget(id) }
        reload()
    }

    // MARK: Keyboard

    /// Keys while the grid has focus. Returns false for keys it leaves alone.
    func handleKey(_ key: KeyEquivalent, modifiers: EventModifiers) -> (handled: Bool, scrollTo: UUID?) {
        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)
        switch key {
        case .leftArrow: return (true, moveCursor(dx: -1, dy: 0, extend: shift))
        case .rightArrow: return (true, moveCursor(dx: 1, dy: 0, extend: shift))
        case .upArrow: return (true, command ? moveCursor(toIndex: 0, extend: shift) : moveCursor(dx: 0, dy: -1, extend: shift))
        case .downArrow:
            if command { loadAll(); return (true, moveCursor(toIndex: clips.count - 1, extend: shift)) }
            return (true, moveCursor(dx: 0, dy: 1, extend: shift))
        case .home: return (true, moveCursor(toIndex: 0, extend: shift))
        case .end:
            loadAll()
            return (true, moveCursor(toIndex: clips.count - 1, extend: shift))
        case .delete, .deleteForward:
            // ⌘⌫ only; a plain Delete is left alone.
            guard command, !selection.isEmpty else { return (false, nil) }
            deleteSelected()
            return (true, cursor)
        case .return:
            guard let c = singleSelection else { return (false, nil) }
            open(c.id)
            return (true, nil)
        case .escape:
            guard !selection.isEmpty else { return (false, nil) }
            clearSelection()
            return (true, nil)
        default:
            guard command, !shift else { return (false, nil) }
            switch key.character {
            case "a":
                selectAll()
                return (true, nil)
            case "c":
                guard let c = singleSelection else { return (false, nil) }
                copy(c.id)
                return (true, nil)
            default:
                return (false, nil)
            }
        }
    }
}

/// One card's own motion in the grid: the select pop and the press dip on the card, and the
/// panel's `CardLook` for its buttons and thumbnail. Driven by the panel's motion clock.
@MainActor @Observable
final class ClipsCardMotion: MotionTarget {
    private(set) var scale = 1.0
    @ObservationIgnored let pop: Anim
    @ObservationIgnored let dip: Anim
    @ObservationIgnored let look = CardLook()
    /// On screen now, so a thumbnail that arrives is born blurred.
    @ObservationIgnored var visible = false

    init() {
        pop = Anim(1, owner: nil, eps: 0.0005)
        dip = Anim(1, owner: nil, eps: 0.0005)
        pop.owner = self
        dip.owner = self
        look.isLive = { [weak self] in self?.visible ?? false }
    }

    func render() {
        let s = pop.v * dip.v
        if s != scale { scale = s }
    }

    func rest() {
        pop.set(1)
        dip.set(1)
        look.rest()
        render()
    }
}

extension ClipsModel {
    /// The accessibility display settings now, as the panel reads them.
    static func liveTheme() -> Theme {
        let ws = NSWorkspace.shared
        return Theme(
            increaseContrast: DebugFlags.increaseContrast || ws.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: DebugFlags.reduceTransparency || ws.accessibilityDisplayShouldReduceTransparency,
            reduceMotion: DebugFlags.reduceMotion || ws.accessibilityDisplayShouldReduceMotion)
    }
}

/// The confirmation both sections show before deleting every clip.
struct ClipsClearConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let count: Int
    let action: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Clear all clips?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Clear All", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes \(ClipsFormat.clips(count, all: true)) and their images from this Mac. You can't undo this.")
        }
    }
}

/// Numbers and sizes as the panel writes them (en-GB grouping).
@MainActor
enum ClipsFormat {
    private static let gb = Locale(identifier: "en_GB")

    static func number(_ n: Int) -> String { n.formatted(.number.locale(gb)) }

    /// "1 clip", "1,284 clips"; with `all`, "all 1,284 clips" (or "the 1 clip").
    static func clips(_ n: Int, all: Bool = false) -> String {
        if all { return n == 1 ? "the 1 clip" : "all \(number(n)) clips" }
        return "\(number(n)) \(n == 1 ? "clip" : "clips")"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        // "0 bytes", not "Zero KB".
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ b: Int64) -> String { byteFormatter.string(fromByteCount: b) }

    /// "30 days", "1 week", "12 hours".
    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let day = 86_400
        if s >= day, s % (7 * day) == 0 {
            let w = s / (7 * day)
            return w == 1 ? "1 week" : "\(w) weeks"
        }
        if s >= day, s % day == 0 {
            let d = s / day
            return d == 1 ? "1 day" : "\(number(d)) days"
        }
        let h = max(s / 3600, 1)
        return h == 1 ? "1 hour" : "\(h) hours"
    }
}

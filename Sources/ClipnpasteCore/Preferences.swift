import Foundation
import Observation

/// Every setting, kept in one UserDefaults suite and observable, so SwiftUI binds to it and the
/// panel reads it live. Defaults are the approved values (plan, 27 Oct 2026).
@MainActor @Observable
public final class Preferences {
    public enum Key: String, CaseIterable, Sendable {
        case dragTilt, dragOut, afterDrop, cardPop, selection, entrance, reduceMotion, slowMotion
        case panelRows, cardButtons, appearance, glass
        case openOn, showMenuBarIcon, showInDock
        case maxClips, maxImageBytes, autoClearDays, ignoredApps, captureUniversalClipboard
        case settingsSection, settingsFrame, welcomed, hasSeenWelcome
        case checkForUpdates, lastUpdateCheck
    }

    public enum DragTilt: String, CaseIterable, Sendable { case speed, fixed45 = "45" }
    public enum DragOut: String, CaseIterable, Sendable { case strip, slide, stay }
    public enum AfterDrop: String, CaseIterable, Sendable { case growBack = "grow", close }
    public enum Selection: String, CaseIterable, Sendable { case slide, flip }
    public enum Entrance: String, CaseIterable, Sendable { case stagger, together }
    public enum ReduceMotion: String, CaseIterable, Sendable { case system, always }
    public enum CardButtons: String, CaseIterable, Sendable { case hoverAndSelected = "hover", always }
    public enum Appearance: String, CaseIterable, Sendable { case system, light, dark }
    public enum Glass: String, CaseIterable, Sendable { case liquid, classic, solid }
    public enum Screen: String, CaseIterable, Sendable { case pointer, main }

    public static let cardPops = [1.03, 1.08]
    public static let rowChoices = [1, 2, 3]
    public static let clipChoices = [500, 1_000, 2_500, 5_000, 10_000, 25_000]
    public static let imageChoices: [Int64] = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000]
    /// 0 is Never.
    public static let autoClearChoices = [1, 7, 30, 90, 365, 0]

    // Motion
    public var dragTilt: DragTilt = .speed { didSet { put(dragTilt.rawValue, .dragTilt) } }
    public var dragOut: DragOut = .strip { didSet { put(dragOut.rawValue, .dragOut) } }
    public var afterDrop: AfterDrop = .growBack { didSet { put(afterDrop.rawValue, .afterDrop) } }
    public var cardPop: Double = 1.08 { didSet { put(cardPop, .cardPop) } }
    public var selection: Selection = .slide { didSet { put(selection.rawValue, .selection) } }
    public var entrance: Entrance = .stagger { didSet { put(entrance.rawValue, .entrance) } }
    public var reduceMotion: ReduceMotion = .system { didSet { put(reduceMotion.rawValue, .reduceMotion) } }
    /// Slow motion ×5 is for inspecting curves: it lasts until the app quits and is never saved.
    public var slowMotion = false { didSet { changed(.slowMotion) } }

    // Panel
    /// Rows the panel opens at; dragging the pill changes it too.
    public var panelRows = 1 { didSet { put(panelRows, .panelRows) } }
    public var cardButtons: CardButtons = .hoverAndSelected { didSet { put(cardButtons.rawValue, .cardButtons) } }
    public var appearance: Appearance = .system { didSet { put(appearance.rawValue, .appearance) } }
    public var glass: Glass = .liquid { didSet { put(glass.rawValue, .glass) } }

    // General
    public var openOn: Screen = .pointer { didSet { put(openOn.rawValue, .openOn) } }
    public var showMenuBarIcon = true { didSet { put(showMenuBarIcon, .showMenuBarIcon) } }
    public var showInDock = false { didSet { put(showInDock, .showInDock) } }

    // Privacy
    public var maxClips = 5_000 { didSet { put(maxClips, .maxClips) } }
    public var maxImageBytes: Int64 = 2_000_000_000 { didSet { put(maxImageBytes, .maxImageBytes) } }
    /// Clips not copied for this many days are deleted; 0 keeps them forever.
    public var autoClearDays = 30 { didSet { put(autoClearDays, .autoClearDays) } }
    /// Bundle ids whose copies are never kept, on top of the built-in password managers.
    public var ignoredApps: [String] = [] { didSet { put(ignoredApps, .ignoredApps) } }
    public var captureUniversalClipboard = true { didSet { put(captureUniversalClipboard, .captureUniversalClipboard) } }

    // Updates
    /// Settings › About › Check for updates automatically: at most once a day, silently.
    public var checkForUpdates = true { didSet { put(checkForUpdates, .checkForUpdates) } }
    /// When GitHub was last asked, by hand or by itself.
    public var lastUpdateCheck: Date? { didSet { put(lastUpdateCheck?.timeIntervalSince1970, .lastUpdateCheck) } }

    // The Settings window itself
    public var settingsSection = "overview" { didSet { put(settingsSection, .settingsSection) } }
    public var settingsFrame: String? { didSet { put(settingsFrame, .settingsFrame) } }
    /// The Settings window has been shown once, on the first launch.
    public var welcomed = false { didSet { put(welcomed, .welcomed) } }
    /// The welcome tour has been shown once, on the first launch (or the first after updating).
    public var hasSeenWelcome = false { didSet { put(hasSeenWelcome, .hasSeenWelcome) } }

    /// Seconds a clip is kept, from the last time it was copied; nil keeps it forever.
    public var maxAge: TimeInterval? { autoClearDays > 0 ? Double(autoClearDays) * 86_400 : nil }

    @ObservationIgnored public let defaults: UserDefaults
    @ObservationIgnored private var observers: [UUID: @MainActor (Key) -> Void] = [:]
    @ObservationIgnored private var loading = false

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        load()
    }

    /// Called after every change, with the key that changed.
    @discardableResult
    public func observe(_ f: @escaping @MainActor (Key) -> Void) -> UUID {
        let token = UUID()
        observers[token] = f
        return token
    }

    public func removeObserver(_ token: UUID) { observers[token] = nil }

    /// Removes every saved value (the window's own state included); the defaults apply again.
    public func resetAll() {
        for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
        load()
        for key in Key.allCases { changed(key) }
    }

    private func load() {
        loading = true
        defer { loading = false }
        let d = defaults
        func pick<T: RawRepresentable>(_ key: Key, _ fallback: T) -> T where T.RawValue == String {
            d.string(forKey: key.rawValue).flatMap { T(rawValue: $0) } ?? fallback
        }
        func number(_ key: Key) -> Double? { (d.object(forKey: key.rawValue) as? NSNumber)?.doubleValue }
        func flag(_ key: Key, _ fallback: Bool) -> Bool { (d.object(forKey: key.rawValue) as? NSNumber)?.boolValue ?? fallback }

        dragTilt = pick(.dragTilt, DragTilt.speed)
        dragOut = pick(.dragOut, DragOut.strip)
        afterDrop = pick(.afterDrop, AfterDrop.growBack)
        cardPop = number(.cardPop).flatMap { v in Self.cardPops.first { abs($0 - v) < 0.0001 } } ?? 1.08
        selection = pick(.selection, Selection.slide)
        entrance = pick(.entrance, Entrance.stagger)
        reduceMotion = pick(.reduceMotion, ReduceMotion.system)
        slowMotion = false
        panelRows = number(.panelRows).map { min(max(Int($0), 1), 3) } ?? 1
        cardButtons = pick(.cardButtons, CardButtons.hoverAndSelected)
        appearance = pick(.appearance, Appearance.system)
        glass = pick(.glass, Glass.liquid)
        openOn = pick(.openOn, Screen.pointer)
        showMenuBarIcon = flag(.showMenuBarIcon, true)
        showInDock = flag(.showInDock, false)
        maxClips = number(.maxClips).map { max(Int($0), 1) } ?? 5_000
        maxImageBytes = number(.maxImageBytes).map { max(Int64($0), 1) } ?? 2_000_000_000
        autoClearDays = number(.autoClearDays).map { max(Int($0), 0) } ?? 30
        ignoredApps = d.stringArray(forKey: Key.ignoredApps.rawValue) ?? []
        captureUniversalClipboard = flag(.captureUniversalClipboard, true)
        checkForUpdates = flag(.checkForUpdates, true)
        lastUpdateCheck = number(.lastUpdateCheck).map { Date(timeIntervalSince1970: $0) }
        settingsSection = d.string(forKey: Key.settingsSection.rawValue) ?? "overview"
        settingsFrame = d.string(forKey: Key.settingsFrame.rawValue)
        welcomed = flag(.welcomed, false)
        hasSeenWelcome = flag(.hasSeenWelcome, false)
    }

    private func put(_ value: Any?, _ key: Key) {
        guard !loading else { return }
        if let value { defaults.set(value, forKey: key.rawValue) } else { defaults.removeObject(forKey: key.rawValue) }
        changed(key)
    }

    private func changed(_ key: Key) {
        guard !loading else { return }
        for o in observers.values { o(key) }
    }
}

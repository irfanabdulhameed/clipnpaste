import AppKit
import Carbon
import ClipnpasteCore

/// A global shortcut through Carbon's RegisterEventHotKey: no permission needed, and the
/// keystroke is swallowed so the app in front never sees it.
@MainActor
final class HotKey {
    private static let signature: OSType = 0x434C_504E // "CLPN"
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `keyCode` is a virtual key code; `modifiers` are Carbon masks (cmdKey, controlKey, ...).
    /// Returns nil if registration fails, for example when another app holds the combination.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else {
            appLog("Hotkey registration failed: \(status)")
            debugLog("hotkey registration failed: \(status)")
            return nil
        }
        ref = hotKeyRef
        Self.actions[id] = action
        debugLog("hotkey registered: key \(keyCode), modifiers \(modifiers)")
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr else { return status }
            let id = hotKey.id
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Keeps one global shortcut registered and moves it when the shortcut changes.
/// With `live` false (checks and demos) nothing is registered with the system.
@MainActor
final class HotKeyManager {
    private(set) var shortcut: Shortcut
    private var hotKey: HotKey?
    private let live: Bool
    private let simulateConflict: Bool
    private let action: () -> Void

    init(shortcut: Shortcut, live: Bool, simulateConflict: Bool = false, action: @escaping () -> Void) {
        self.shortcut = shortcut
        self.live = live
        self.simulateConflict = simulateConflict
        self.action = action
    }

    func start() { resume() }

    /// Lets the shortcut reach the recorder instead of opening the panel.
    func pause() {
        hotKey?.unregister()
        hotKey = nil
    }

    func resume() {
        guard live, hotKey == nil else { return }
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: Self.carbon(shortcut.modifiers), action: action)
    }

    /// Registers the new combination at once. If another app holds it, the old one stays and this returns false.
    func change(to new: Shortcut) -> Bool {
        pause()
        if simulateConflict { resume(); return false }
        if live {
            guard let fresh = HotKey(keyCode: new.keyCode, modifiers: Self.carbon(new.modifiers), action: action) else {
                resume()
                return false
            }
            hotKey = fresh
        }
        shortcut = new
        return true
    }

    static func carbon(_ m: Shortcut.Modifiers) -> UInt32 {
        var mask = 0
        if m.contains(.command) { mask |= cmdKey }
        if m.contains(.control) { mask |= controlKey }
        if m.contains(.option) { mask |= optionKey }
        if m.contains(.shift) { mask |= shiftKey }
        return UInt32(mask)
    }
}

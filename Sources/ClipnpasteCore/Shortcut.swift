import Foundation

/// A global shortcut: a virtual key code and modifier keys.
public struct Shortcut: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public enum Check: Equatable, Sendable {
        case valid
        /// Esc on its own: stop recording.
        case cancel
        /// macOS 15 and later refuse global shortcuts without ⌘ or ⌃.
        case needsModifier
    }

    public static let escapeKeyCode: UInt32 = 53

    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static func check(keyCode: UInt32, modifiers: Modifiers) -> Check {
        if keyCode == escapeKeyCode && modifiers.isEmpty { return .cancel }
        if modifiers.contains(.command) || modifiers.contains(.control) { return .valid }
        return .needsModifier
    }

    public var check: Check { Self.check(keyCode: keyCode, modifiers: modifiers) }

    /// "⌃⌘V". `keyName` gives the character a key types in the current layout.
    public func label(keyName: (UInt32) -> String?) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyLabel(keyCode, keyName: keyName)
    }

    private static let fixedKeys: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 71: "⌧", 76: "⌅", 115: "↖", 116: "⇞", 117: "⌦",
        119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static func keyLabel(_ code: UInt32, keyName: (UInt32) -> String?) -> String {
        if let fixed = fixedKeys[code] { return fixed }
        if let name = keyName(code)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name.uppercased()
        }
        return "Key \(code)"
    }
}

/// Keeps the chosen shortcut in UserDefaults. Nothing stored means the default.
public struct ShortcutStore: @unchecked Sendable {
    public static let keyCodeKey = "shortcut.keyCode"
    public static let modifiersKey = "shortcut.modifiers"

    private let defaults: UserDefaults
    public let defaultShortcut: Shortcut

    /// `defaultKeyCode` is the key that types "v" in the current layout.
    public init(defaults: UserDefaults, defaultKeyCode: UInt32) {
        self.defaults = defaults
        defaultShortcut = Shortcut(keyCode: defaultKeyCode, modifiers: [.control, .command])
    }

    public var current: Shortcut {
        guard defaults.object(forKey: Self.keyCodeKey) != nil, defaults.object(forKey: Self.modifiersKey) != nil else {
            return defaultShortcut
        }
        let saved = Shortcut(keyCode: UInt32(truncatingIfNeeded: defaults.integer(forKey: Self.keyCodeKey)),
                             modifiers: Shortcut.Modifiers(rawValue: UInt8(truncatingIfNeeded: defaults.integer(forKey: Self.modifiersKey))))
        return saved.check == .valid ? saved : defaultShortcut
    }

    public var isDefault: Bool { current == defaultShortcut }

    public func save(_ shortcut: Shortcut) {
        if shortcut == defaultShortcut { reset(); return }
        defaults.set(Int(shortcut.keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(shortcut.modifiers.rawValue), forKey: Self.modifiersKey)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.keyCodeKey)
        defaults.removeObject(forKey: Self.modifiersKey)
    }
}

import Foundation
import Testing
@testable import ClipnpasteCore

@Suite struct ShortcutTests {
    private let v: UInt32 = 9
    private func name(_ code: UInt32) -> String? { code == 9 ? "v" : code == 0 ? "a" : nil }

    @Test func commandOrControlIsRequired() {
        #expect(Shortcut.check(keyCode: v, modifiers: [.control, .command]) == .valid)
        #expect(Shortcut.check(keyCode: v, modifiers: .command) == .valid)
        #expect(Shortcut.check(keyCode: v, modifiers: .control) == .valid)
        #expect(Shortcut.check(keyCode: v, modifiers: []) == .needsModifier)
        #expect(Shortcut.check(keyCode: v, modifiers: .shift) == .needsModifier)
        #expect(Shortcut.check(keyCode: v, modifiers: [.option, .shift]) == .needsModifier)
    }

    @Test func escapeAloneCancels() {
        #expect(Shortcut.check(keyCode: 53, modifiers: []) == .cancel)
        #expect(Shortcut.check(keyCode: 53, modifiers: .command) == .valid)
        #expect(Shortcut.check(keyCode: 53, modifiers: .shift) == .needsModifier)
    }

    @Test func labelUsesStandardModifierOrder() {
        #expect(Shortcut(keyCode: v, modifiers: [.command, .control]).label(keyName: name) == "⌃⌘V")
        #expect(Shortcut(keyCode: 0, modifiers: [.command, .shift, .option, .control]).label(keyName: name) == "⌃⌥⇧⌘A")
    }

    @Test func labelNamesSpecialAndUnknownKeys() {
        #expect(Shortcut(keyCode: 49, modifiers: .command).label(keyName: name) == "⌘Space")
        #expect(Shortcut(keyCode: 122, modifiers: .control).label(keyName: name) == "⌃F1")
        #expect(Shortcut(keyCode: 126, modifiers: [.control, .command]).label(keyName: name) == "⌃⌘↑")
        #expect(Shortcut(keyCode: 200, modifiers: .command).label(keyName: name) == "⌘Key 200")
    }

    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "clipnpaste.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func storeDefaultsSavesAndResets() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults, defaultKeyCode: v)
        #expect(store.current == Shortcut(keyCode: v, modifiers: [.control, .command]))
        #expect(store.isDefault)
        let custom = Shortcut(keyCode: 0, modifiers: [.command, .option])
        store.save(custom)
        #expect(store.current == custom)
        #expect(!store.isDefault)
        // A new store over the same defaults sees it.
        #expect(ShortcutStore(defaults: defaults, defaultKeyCode: v).current == custom)
        store.reset()
        #expect(store.isDefault)
    }

    @Test func storeIgnoresInvalidSavedValue() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: ShortcutStore.keyCodeKey)
        defaults.set(Int(Shortcut.Modifiers.shift.rawValue), forKey: ShortcutStore.modifiersKey)
        #expect(ShortcutStore(defaults: defaults, defaultKeyCode: v).isDefault)
    }
}

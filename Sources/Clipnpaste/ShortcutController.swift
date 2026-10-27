import AppKit
import ClipnpasteCore

/// Owns the chosen shortcut: saves it, keeps it registered, and opens the recorder.
@MainActor
final class ShortcutController {
    private let store: ShortcutStore
    private let hotKeys: HotKeyManager
    private let useClassicBlur: () -> Bool
    private var recorder: RecorderWindowController?

    init(useClassicBlur: @escaping () -> Bool, action: @escaping () -> Void) {
        self.useClassicBlur = useClassicBlur
        store = ShortcutStore(defaults: Sandbox.defaults, defaultKeyCode: UInt32(Paster.vKeyCode()))
        hotKeys = HotKeyManager(shortcut: store.current, live: !Sandbox.isOn,
                                simulateConflict: Sandbox.args.contains("--simulate-conflict"), action: action)
    }

    var shortcut: Shortcut { hotKeys.shortcut }
    var defaultShortcut: Shortcut { store.defaultShortcut }
    var isDefault: Bool { shortcut == store.defaultShortcut }
    var label: String { label(for: shortcut) }
    func label(for s: Shortcut) -> String { s.label(keyName: KeyNames.name) }

    /// Called whenever the shortcut changes, so the menu can show the new label.
    var onChange: (() -> Void)?
    /// Posted whenever the shortcut changes, for Settings.
    static let didChange = Notification.Name("ClipnpasteShortcutDidChange")

    func start() {
        hotKeys.start()
        if Sandbox.args.contains("--show-recorder") { showRecorder() }
    }

    /// Saves and registers at once. False when another app holds the combination; the old one stays.
    func apply(_ s: Shortcut) -> Bool {
        guard hotKeys.change(to: s) else { return false }
        store.save(s)
        onChange?()
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return true
    }

    func reset() -> Bool { apply(store.defaultShortcut) }
    func pauseHotKey() { hotKeys.pause() }
    func resumeHotKey() { hotKeys.resume() }

    func showRecorder() {
        if recorder == nil {
            recorder = RecorderWindowController(shortcuts: self, useClassicBlur: useClassicBlur) { [weak self] in
                self?.recorder = nil
            }
        }
        recorder?.show()
    }
}

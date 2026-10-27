import AppKit
import ClipnpasteCore

/// The menu bar icon: open the panel, shortcut, launch at login, Accessibility status,
/// the classic blur switch, Quit.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let openItem = NSMenuItem(title: "Open Clipnpaste", action: #selector(openPanel), keyEquivalent: "")
    private let shortcutItem = NSMenuItem(title: "", action: #selector(openRecorder), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
    private let loginNoteItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
    private let classicItem = NSMenuItem(title: "Use classic blur", action: #selector(toggleClassicBlur), keyEquivalent: "")
    private let panel: PanelController
    private let shortcuts: ShortcutController
    private var loginError: String?

    init(panel: PanelController, shortcuts: ShortcutController) {
        self.panel = panel
        self.shortcuts = shortcuts
        super.init()
        item.button?.image = MenuBarGlyph.image()
        accessibilityItem.toolTip = "Open Accessibility in System Settings"
        for i in [openItem, shortcutItem, loginItem, loginNoteItem, accessibilityItem, classicItem] { i.target = self }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(shortcutItem)
        menu.addItem(loginItem)
        menu.addItem(loginNoteItem)
        menu.addItem(accessibilityItem)
        menu.addItem(classicItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clipnpaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        shortcuts.onChange = { [weak self] in self?.refresh() }
        refresh()
        if Sandbox.args.contains("--fake-login-approval") {
            LaunchAtLogin.configureSandbox(needsApproval: true)
        }
        if Sandbox.isOn, Sandbox.args.contains("--open-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.item.button?.performClick(nil) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func refresh() {
        shortcutItem.title = "Shortcut…  \(shortcuts.label)"
        switch LaunchAtLogin.status {
        case .enabled:
            loginItem.state = .on
            loginNoteItem.isHidden = loginError == nil
        case .needsApproval:
            loginItem.state = .mixed
            loginNoteItem.isHidden = false
        case .off, .unavailable:
            loginItem.state = .off
            loginNoteItem.isHidden = loginError == nil
        }
        if LaunchAtLogin.status == .needsApproval {
            loginNoteItem.title = "Needs approval in System Settings…"
            loginNoteItem.action = #selector(openLoginSettings)
            loginNoteItem.isEnabled = true
        } else if let loginError {
            loginNoteItem.title = loginError
            loginNoteItem.action = nil
            loginNoteItem.isEnabled = false
        }
        accessibilityItem.title = Paster.canPost ? "Accessibility: Granted" : "Accessibility: Not granted…"
        classicItem.state = panel.useClassicBlur ? .on : .off
    }

    @objc private func openPanel() { panel.open() }
    @objc private func openRecorder() { shortcuts.showRecorder() }
    @objc private func openAccessibility() { Paster.openAccessibilitySettings() }
    @objc private func toggleClassicBlur() { panel.useClassicBlur.toggle() }
    @objc private func openLoginSettings() { LaunchAtLogin.openSettings() }

    @objc private func toggleLogin() {
        loginError = nil
        let turnOn = LaunchAtLogin.status == .off || LaunchAtLogin.status == .unavailable
        do {
            try LaunchAtLogin.setEnabled(turnOn)
        } catch {
            loginError = "Couldn't change it: \(error.localizedDescription)"
        }
        refresh()
    }
}

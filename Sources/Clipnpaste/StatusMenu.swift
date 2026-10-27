import AppKit

/// The menu bar icon: open the panel, Accessibility status, the classic blur switch, Quit.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let accessibilityItem = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
    private let classicItem = NSMenuItem(title: "Use classic blur", action: #selector(toggleClassicBlur), keyEquivalent: "")
    private let panel: PanelController

    init(panel: PanelController) {
        self.panel = panel
        super.init()
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipnpaste")
        let open = NSMenuItem(title: "Open Clipnpaste", action: #selector(openPanel), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.control, .command]
        accessibilityItem.toolTip = "Open Accessibility in System Settings"
        for i in [open, accessibilityItem, classicItem] { i.target = self }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        menu.addItem(classicItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clipnpaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func refresh() {
        accessibilityItem.title = Paster.canPost ? "Accessibility: On" : "Accessibility: Off"
        classicItem.state = panel.useClassicBlur ? .on : .off
    }

    @objc private func openPanel() { panel.open() }
    @objc private func openAccessibility() { Paster.openAccessibilitySettings() }
    @objc private func toggleClassicBlur() { panel.useClassicBlur.toggle() }
}

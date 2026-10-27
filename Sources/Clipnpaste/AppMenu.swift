import AppKit

/// The main menu: shown in the menu bar only while the app is in the Dock, but always there for
/// key equivalents. ⌘, opens Settings from anywhere, the panel included. The other commands
/// stand aside while the non-activating panel has the keyboard, so its keys keep reaching it
/// (⌘Q in the panel does nothing, as before).
@MainActor
final class AppMenu: NSObject, NSMenuItemValidation {
    private let openSettings: () -> Void
    private let showAbout: () -> Void
    private let panelIsKey: () -> Bool

    init(openSettings: @escaping () -> Void, showAbout: @escaping () -> Void, panelIsKey: @escaping () -> Bool) {
        self.openSettings = openSettings
        self.showAbout = showAbout
        self.panelIsKey = panelIsKey
        super.init()
        NSApp.mainMenu = build()
    }

    private func build() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(title: "Clipnpaste")
        app.addItem(item("About Clipnpaste", #selector(about)))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(settings), ","))
        app.addItem(.separator())
        app.addItem(item("Hide Clipnpaste", #selector(hide), "h"))
        let others = item("Hide Others", #selector(hideOthers), "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(others)
        app.addItem(item("Show All", #selector(showAll)))
        app.addItem(.separator())
        app.addItem(item("Quit Clipnpaste", #selector(quit), "q"))

        let window = NSMenu(title: "Window")
        window.addItem(item("Close", #selector(closeWindow), "w"))
        window.addItem(item("Minimize", #selector(minimize), "m"))

        for sub in [app, window] {
            let holder = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            holder.submenu = sub
            main.addItem(holder)
        }
        NSApp.windowsMenu = window
        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(settings), #selector(about): return true
        case #selector(closeWindow): return !panelIsKey() && NSApp.keyWindow?.styleMask.contains(.closable) == true
        case #selector(minimize): return !panelIsKey() && NSApp.keyWindow?.styleMask.contains(.miniaturizable) == true
        default: return !panelIsKey()
        }
    }

    @objc private func about() { showAbout() }
    @objc private func settings() { openSettings() }
    @objc private func hide() { NSApp.hide(nil) }
    @objc private func hideOthers() { NSApp.hideOtherApplications(nil) }
    @objc private func showAll() { NSApp.unhideAllApplications(nil) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func closeWindow() { NSApp.keyWindow?.performClose(nil) }
    @objc private func minimize() { NSApp.keyWindow?.performMiniaturize(nil) }
}

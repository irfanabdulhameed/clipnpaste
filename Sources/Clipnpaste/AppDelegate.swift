import AppKit
import Carbon
import ClipnpasteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var panel: PanelController?
    private var shortcuts: ShortcutController?
    private var statusMenu: StatusMenu?
    private var settings: SettingsWindowController?
    private var appMenu: AppMenu?
    private let prefs = Preferences.app

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()
        let env: AppEnvironment
        do {
            env = try AppEnvironment.make()
        } catch {
            appLog("Could not open the clip store: \(error)")
            env = AppEnvironment.fallback()
        }
        environment = env
        let panel = PanelController(store: env.store, watcher: env.watcher)
        self.panel = panel
        OverviewHooks.openPanel = { [weak panel] in panel?.open() }
        // The chosen shortcut (⌃⌘V by default) toggles the panel. A debug run (any check flag) gets no
        // global shortcut (the manager is not live in sandbox mode) and no menu bar icon, so an
        // installed copy that is running keeps ⌃⌘V and nothing it shows changes.
        let shortcuts = ShortcutController(useClassicBlur: { [weak panel] in panel?.useClassicBlur ?? false }) { [weak panel] in
            panel?.toggle()
        }
        self.shortcuts = shortcuts
        shortcuts.start()
        let settings = SettingsWindowController(env: env, shortcuts: shortcuts)
        self.settings = settings
        panel.onOpenSettings = { [weak self] in self?.showSettings() }
        appMenu = AppMenu(openSettings: { [weak self] in self?.showSettings() },
                          showAbout: { [weak self] in self?.showSettings(.about) },
                          panelIsKey: { [weak panel] in panel?.panel.isKeyWindow ?? false })
        if !DebugFlags.usesDemoStore {
            let menu = StatusMenu(panel: panel, shortcuts: shortcuts)
            menu.onOpenSettings = { [weak self] in self?.showSettings() }
            menu.isVisible = prefs.showMenuBarIcon
            statusMenu = menu
        } else {
            debugLog("debug run: in-memory store, no watcher, no hotkey, no menu bar icon")
        }
        applyDock()
        prefs.observe { [weak self] key in
            guard let self else { return }
            switch key {
            case .appearance: applyAppearance()
            case .showInDock: applyDock()
            case .showMenuBarIcon: statusMenu?.isVisible = prefs.showMenuBarIcon
            default: break
            }
        }

        if let name = DebugFlags.showSettings {
            showSettings(SettingsSection(rawValue: name) ?? .overview)
        } else if !prefs.welcomed, !DebugFlags.usesDemoStore {
            // Once, on the first launch: the Overview says what the app is and how to open it.
            prefs.welcomed = true
            showSettings(.overview)
        }
        if DebugFlags.showPanel || DebugFlags.selfTest || DebugFlags.scene != nil {
            Task {
                panel.open()
                if DebugFlags.selfTest { await panel.runSelfTest() }
                if let scene = DebugFlags.scene { await panel.showScene(scene) }
            }
        }
        ClipsPreview.showIfAsked(env: env)
    }

    /// Opened again from Applications, Spotlight or the Dock while running: Settings, the way back
    /// when both the menu-bar icon and the Dock icon are off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.watcher.stop()
        DemoExtras.cleanUp()
        DragPasteboard.cleanUp()
    }

    /// Closes the panel first, then shows Settings (on its last section unless one is given).
    func showSettings(_ section: SettingsSection? = nil) {
        if let panel, panel.isOpen { panel.close() }
        settings?.show(section)
    }

    /// `--appearance light|dark` wins over the setting, for screenshots.
    private func applyAppearance() {
        let choice = DebugFlags.appearance ?? prefs.appearance.rawValue
        switch choice {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Settings › General › Show in Dock, live. Switching the policy can drop the app from the
    /// front, so an open Settings window is brought back.
    private func applyDock() {
        let policy: NSApplication.ActivationPolicy = prefs.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if let settings, settings.isVisible {
            DispatchQueue.main.async { settings.show() }
        }
    }
}

import AppKit
import Carbon
import ClipnpasteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var panel: PanelController?
    private var shortcuts: ShortcutController?
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch DebugFlags.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
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
        if !DebugFlags.usesDemoStore {
            statusMenu = StatusMenu(panel: panel, shortcuts: shortcuts)
        } else {
            debugLog("debug run: in-memory store, no watcher, no hotkey, no menu bar icon")
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

    func applicationWillTerminate(_ notification: Notification) {
        environment?.watcher.stop()
        DemoExtras.cleanUp()
        DragPasteboard.cleanUp()
    }
}

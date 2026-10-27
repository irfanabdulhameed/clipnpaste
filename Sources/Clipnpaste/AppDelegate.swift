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
        // The chosen shortcut (⌃⌘V by default) toggles the panel.
        let shortcuts = ShortcutController(useClassicBlur: { [weak panel] in panel?.useClassicBlur ?? false }) { [weak panel] in
            panel?.toggle()
        }
        self.shortcuts = shortcuts
        shortcuts.start()
        statusMenu = StatusMenu(panel: panel, shortcuts: shortcuts)
        if DebugFlags.showPanel || DebugFlags.selfTest {
            Task {
                panel.open()
                if DebugFlags.selfTest { await panel.runSelfTest() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.watcher.stop()
        DemoExtras.cleanUp()
    }
}

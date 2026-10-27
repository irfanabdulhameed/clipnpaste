import AppKit
import Carbon
import ClipnpasteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var panel: PanelController?
    private var hotKey: HotKey?
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
        // A debug run (any check flag) takes no global shortcut and adds no menu bar icon, so an
        // installed copy that is running keeps ⌃⌘V and nothing it shows changes.
        if !DebugFlags.usesDemoStore {
            // ⌃⌘V toggles the panel.
            hotKey = HotKey(keyCode: UInt32(Paster.vKeyCode()), modifiers: UInt32(cmdKey | controlKey)) { [weak panel] in
                panel?.toggle()
            }
            statusMenu = StatusMenu(panel: panel)
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.watcher.stop()
        DemoExtras.cleanUp()
        DragPasteboard.cleanUp()
    }
}

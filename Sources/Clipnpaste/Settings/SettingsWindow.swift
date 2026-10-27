import AppKit
import SwiftUI
import ClipnpasteCore

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case overview, clips, general, panel, motion, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .clips: "Clips"
        case .general: "General"
        case .panel: "Panel"
        case .motion: "Motion"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .clips: "doc.on.clipboard"
        case .general: "gearshape"
        case .panel: "rectangle.bottomhalf.inset.filled"
        case .motion: "cursorarrow.motionlines"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }
}

/// What the Settings views share: the app's environment, the shortcut, and the selected section.
@MainActor @Observable
final class SettingsModel {
    let env: AppEnvironment
    let shortcuts: ShortcutController
    let recorder: ShortcutRecorderModel
    var prefs: Preferences { env.preferences }

    var section: SettingsSection {
        didSet {
            if section != oldValue { prefs.settingsSection = section.rawValue }
            onSection?(section)
        }
    }
    @ObservationIgnored var onSection: ((SettingsSection) -> Void)?

    init(env: AppEnvironment, shortcuts: ShortcutController) {
        self.env = env
        self.shortcuts = shortcuts
        recorder = ShortcutRecorderModel(shortcuts: shortcuts)
        section = SettingsSection(rawValue: env.preferences.settingsSection) ?? .overview
    }
}

/// The Settings window: a SwiftUI split view (system sidebar with Liquid Glass) in a plain
/// titled window. It remembers its size, place and last section in Preferences, never in the
/// window's own autosave, so a debug run keeps them in its sandboxed suite.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 800, height: 580)
    static let minSize = NSSize(width: 660, height: 440)

    let model: SettingsModel
    let window: NSWindow
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { window.isVisible }

    init(env: AppEnvironment, shortcuts: ShortcutController) {
        model = SettingsModel(env: env, shortcuts: shortcuts)
        let host = NSHostingController(rootView: SettingsView(model: model))
        host.sizingOptions = []
        // The toolbar comes from SwiftUI; the title stays "Clipnpaste Settings", with the section under it.
        host.sceneBridgingOptions = [.toolbars]
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()
        window.contentViewController = host
        window.title = "Clipnpaste Settings"
        window.subtitle = model.section.title
        model.onSection = { [weak window] in window?.subtitle = $0.title }
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.minSize = Self.minSize
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        window.delegate = self
        if let saved = env.preferences.settingsFrame {
            window.setFrame(from: saved)
            if window.frame.width < Self.minSize.width || window.frame.height < Self.minSize.height {
                window.setContentSize(Self.defaultSize)
            }
        } else {
            window.setContentSize(Self.defaultSize)
            window.center()
        }
    }

    /// Brings the window forward, on `section` if given. The app activates while it is open; the
    /// app that was in front gets the keyboard back when it closes.
    func show(_ section: SettingsSection? = nil) {
        if let section { model.section = section }
        if !window.isVisible || !NSApp.isActive {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        }
        if !window.isOnActiveSpace, window.isVisible { window.orderOut(nil) }
        // A frame saved on a screen that is gone is pulled back onto a visible one.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        if Sandbox.args.contains("--no-activate") {
            // Checks and screenshots: shown in the middle of the main screen, and the app in front
            // keeps the keyboard.
            if let vf = NSScreen.screens.first?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: (vf.midX - window.frame.width / 2).rounded(), y: (vf.midY - window.frame.height / 2).rounded()))
            }
            window.orderFrontRegardless()
        } else {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        debugLog("settings: shown on \(model.section.rawValue), window \(window.windowNumber), title \"\(window.title)\", frame \(window.frame), main screen height \(NSScreen.screens.first?.frame.height ?? 0)")
    }

    func close() { window.performClose(nil) }

    private func saveFrame() { model.prefs.settingsFrame = window.frameDescriptor }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        model.recorder.stop()
        // Without a Dock icon there is nothing to keep the app in front: hand it back.
        if NSApp.activationPolicy() != .regular, let app = previousApp, !app.isTerminated {
            app.activate()
        }
        previousApp = nil
    }
}

import Foundation
import ClipnpasteCore

extension Preferences {
    /// The app's one preferences store. The panel, cards, drag, motion clock and store read it
    /// live. A debug run keeps its own suite, wiped at launch (unless `--keep-prefs`), so checks
    /// start from the approved defaults and never touch the installed app's settings.
    static let app: Preferences = {
        guard Sandbox.isOn else {
            let p = Preferences(defaults: .standard)
            p.migrateClassicBlur()
            return p
        }
        let name = "com.irfanabdulhameed.clipnpaste.debug.preferences"
        let d = UserDefaults(suiteName: name)!
        if !Sandbox.args.contains("--keep-prefs") { d.removePersistentDomain(forName: name) }
        return Preferences(defaults: d)
    }()

    /// v0.1 kept "Use classic blur" under its own key; it becomes the Glass setting once.
    private func migrateClassicBlur() {
        if defaults.object(forKey: Key.glass.rawValue) == nil, defaults.bool(forKey: "useClassicBlur") { glass = .classic }
    }

    /// The capture rules for these settings: the built-in password managers plus the apps added here.
    var captureRules: CaptureRules {
        var rules = CaptureRules(ignoredApps: CaptureRules.passwordManagers.union(ignoredApps))
        rules.captureUniversalClipboard = captureUniversalClipboard
        return rules
    }
}

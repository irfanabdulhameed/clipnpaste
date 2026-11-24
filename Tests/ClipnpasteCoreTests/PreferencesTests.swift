import Testing
import Foundation
@testable import ClipnpasteCore

/// Each test gets its own throwaway suite, never the app's defaults.
@MainActor @Suite struct PreferencesTests {
    private func suite() -> (UserDefaults, String) {
        let name = "com.irfanabdulhameed.clipnpaste.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (d, name)
    }

    @Test func defaultsAreTheApprovedValues() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        let p = Preferences(defaults: d)
        #expect(p.dragOut == .strip)
        #expect(p.afterDrop == .growBack)
        #expect(p.panelRows == 1)
        #expect(p.cardButtons == .hoverAndSelected)
        #expect(p.appearance == .system)
        #expect(p.glass == .liquid)
        #expect(p.openOn == .pointer)
        #expect(p.showMenuBarIcon)
        #expect(p.showInDock == false)
        #expect(p.maxClips == 5_000)
        #expect(p.maxImageBytes == 2_000_000_000)
        #expect(p.autoClearDays == 30)
        #expect(p.maxAge == TimeInterval(30 * 86_400))
        #expect(p.ignoredApps.isEmpty)
        #expect(p.captureUniversalClipboard)
        #expect(p.settingsSection == "overview")
        #expect(p.settingsFrame == nil)
        #expect(p.welcomed == false)
        // Nothing is written until something changes.
        #expect(Preferences.Key.allCases.allSatisfy { d.object(forKey: $0.rawValue) == nil })
    }

    @Test func everyChangePersists() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        let p = Preferences(defaults: d)
        p.dragOut = .slide
        p.afterDrop = .close
        p.panelRows = 3
        p.cardButtons = .always
        p.appearance = .dark
        p.glass = .solid
        p.openOn = .main
        p.showMenuBarIcon = false
        p.showInDock = true
        p.maxClips = 1_000
        p.maxImageBytes = 500_000_000
        p.autoClearDays = 0
        p.ignoredApps = ["com.example.secret"]
        p.captureUniversalClipboard = false
        p.settingsSection = "motion"
        p.settingsFrame = "100 100 720 520 0 0 1920 1080 "
        p.welcomed = true

        let q = Preferences(defaults: d)
        #expect(q.dragOut == .slide)
        #expect(q.afterDrop == .close)
        #expect(q.panelRows == 3)
        #expect(q.cardButtons == .always)
        #expect(q.appearance == .dark)
        #expect(q.glass == .solid)
        #expect(q.openOn == .main)
        #expect(q.showMenuBarIcon == false)
        #expect(q.showInDock)
        #expect(q.maxClips == 1_000)
        #expect(q.maxImageBytes == 500_000_000)
        #expect(q.autoClearDays == 0)
        #expect(q.maxAge == nil)
        #expect(q.ignoredApps == ["com.example.secret"])
        #expect(q.captureUniversalClipboard == false)
        #expect(q.settingsSection == "motion")
        #expect(q.settingsFrame == "100 100 720 520 0 0 1920 1080 ")
        #expect(q.welcomed)
    }

    @Test func retiredMotionChoicesAreDropped() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        for key in Preferences.retiredKeys { d.set("old", forKey: key) }
        d.set("slide", forKey: "dragOut")
        let p = Preferences(defaults: d)
        #expect(Preferences.retiredKeys.allSatisfy { d.object(forKey: $0) == nil })
        #expect(p.dragOut == .slide)
    }

    @Test func badSavedValuesFallBackToDefaults() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        d.set("sideways", forKey: "dragOut")
        d.set(9, forKey: "panelRows")
        d.set(-4, forKey: "autoClearDays")
        d.set(0, forKey: "maxClips")
        let p = Preferences(defaults: d)
        #expect(p.dragOut == .strip)
        #expect(p.panelRows == 3)
        #expect(p.autoClearDays == 0)
        #expect(p.maxClips == 1)
    }

    @Test func observersHearEachChangeOnce() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        let p = Preferences(defaults: d)
        var heard: [Preferences.Key] = []
        let token = p.observe { heard.append($0) }
        p.glass = .classic
        p.panelRows = 2
        p.afterDrop = .close
        #expect(heard == [.glass, .panelRows, .afterDrop])
        p.removeObserver(token)
        p.glass = .liquid
        #expect(heard.count == 3)
    }

    @Test func resetAllRestoresDefaults() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        let p = Preferences(defaults: d)
        p.glass = .solid
        p.maxClips = 500
        p.resetAll()
        #expect(p.glass == .liquid)
        #expect(p.maxClips == 5_000)
        #expect(d.object(forKey: "glass") == nil)
    }
}

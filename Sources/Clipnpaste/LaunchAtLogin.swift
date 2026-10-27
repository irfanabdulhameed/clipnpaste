import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`. In sandbox mode (checks) it only pretends,
/// so a test copy never touches the real login item.
@MainActor
enum LaunchAtLogin {
    enum Status { case enabled, off, needsApproval, unavailable }

    private static var fakeEnabled = false
    private static var fakeNeedsApproval = false

    static func configureSandbox(needsApproval: Bool) { fakeNeedsApproval = needsApproval }

    static var status: Status {
        if Sandbox.isOn { return fakeNeedsApproval ? .needsApproval : (fakeEnabled ? .enabled : .off) }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        default: return .off
        }
    }

    static func setEnabled(_ on: Bool) throws {
        if Sandbox.isOn { fakeEnabled = on; return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSettings() {
        if !Sandbox.isOn { SMAppService.openSystemSettingsLoginItems() }
    }
}

/// Settings checks that must never touch Irfan's real data: any debug or demo flag, or `--sandbox-settings`.
@MainActor
enum Sandbox {
    static let args = ProcessInfo.processInfo.arguments
    static let isOn = args.contains("--sandbox-settings") || DebugFlags.usesDemoStore
    static let defaults: UserDefaults = isOn
        ? UserDefaults(suiteName: "com.irfanabdulhameed.clipnpaste.debug") ?? .standard
        : .standard
}

import Foundation
import os

/// Launch arguments for checks, e.g. `open Clipnpaste.app --args --show-panel --demo-extra`.
enum DebugFlags {
    private static let args = ProcessInfo.processInfo.arguments
    /// Opens the panel at launch and logs its geometry to stderr.
    static let showPanel = args.contains("--show-panel")
    static let selfTest = args.contains("--self-test")
    /// `--scene NAME` opens the panel in one state for a screenshot: pill-hover, pill-press,
    /// pill-limit, grid3, history, drag, strip.
    static let scene: String? = value(after: "--scene")
    static let traceEvents = args.contains("--trace-events")
    /// The self-test and scenes drive the panel with synthetic events.
    static var drivesPanel: Bool { selfTest || scene != nil }
    static let logGeometry = showPanel || selfTest || scene != nil || args.contains("--log-geometry")
    /// History pages in this many clips at a time (200 normally; 40 in the self-test so paging shows).
    static let historyPage: Int? = value(after: "--history-page").flatMap { Int($0) } ?? (selfTest ? 40 : nil)
    /// Adds image, long-text and missing-file clips to the in-memory demo store.
    static let demoExtra = args.contains("--demo-extra")
    /// Shows hover, pressed, copy-confirmed and Tab focus together when the panel opens.
    static let demoStates = args.contains("--demo-states")
    /// Starts with no clips, to see the first-use state.
    static let empty = args.contains("--empty")
    /// `--show-settings SECTION` opens the Settings window on overview, clips, general, panel,
    /// motion, privacy or about (with the demo store and sandboxed settings).
    static let showSettings: String? = value(after: "--show-settings")
    /// Any flag that must not touch the real history or clipboard.
    static var usesDemoStore: Bool {
        selfTest || showPanel || demoExtra || demoStates || empty || scene != nil || showSettings != nil
    }
    static let reduceTransparency = args.contains("--reduce-transparency")
    static let increaseContrast = args.contains("--increase-contrast")
    static let reduceMotion = args.contains("--reduce-motion")
    /// `--appearance light` or `--appearance dark` overrides the system appearance.
    static let appearance: String? = value(after: "--appearance")
    /// `--slow-motion N` runs every animation N times slower, for screenshots of motion mid-flight.
    static let slowMotion: Double = value(after: "--slow-motion").flatMap { Double($0) }.map { max($0, 1) } ?? 1

    private static func value(after flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
}

private let logger = Logger(subsystem: "com.irfanabdulhameed.clipnpaste", category: "app")

/// Check output for `--show-panel` and `--log-geometry`.
func debugLog(_ message: String) {
    guard DebugFlags.logGeometry else { return }
    FileHandle.standardError.write(Data("[Clipnpaste] \(message)\n".utf8))
}

func appLog(_ message: String) {
    logger.error("\(message, privacy: .public)")
}

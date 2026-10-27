import Foundation
import os

/// Launch arguments for checks, e.g. `open Clipnpaste.app --args --show-panel --demo-extra`.
enum DebugFlags {
    private static let args = ProcessInfo.processInfo.arguments
    /// Opens the panel at launch and logs its geometry to stderr.
    static let showPanel = args.contains("--show-panel")
    static let selfTest = args.contains("--self-test")
    static let logGeometry = showPanel || selfTest || args.contains("--log-geometry")
    /// Adds image, long-text and missing-file clips to the in-memory demo store.
    static let demoExtra = args.contains("--demo-extra")
    /// Shows hover, pressed, copy-confirmed and Tab focus together when the panel opens.
    static let demoStates = args.contains("--demo-states")
    /// Starts with no clips, to see the first-use state.
    static let empty = args.contains("--empty")
    static let reduceTransparency = args.contains("--reduce-transparency")
    static let increaseContrast = args.contains("--increase-contrast")
    static let reduceMotion = args.contains("--reduce-motion")
    /// `--appearance light` or `--appearance dark` overrides the system appearance.
    static let appearance: String? = args.firstIndex(of: "--appearance").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
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

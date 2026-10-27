import AppKit
import SwiftUI
import ClipnpasteCore

/// The shortcut recorder's logic for the Settings row: the same field, phases and messages as
/// the recorder window behind the menu's "Shortcut…".
@MainActor @Observable
final class ShortcutRecorderModel {
    private(set) var phase: RecorderPhase = .rest
    private(set) var label: String
    private(set) var isDefault: Bool
    let defaultLabel: String
    @ObservationIgnored private let shortcuts: ShortcutController
    @ObservationIgnored private weak var field: ShortcutField?
    @ObservationIgnored private var token: NSObjectProtocol?

    init(shortcuts: ShortcutController) {
        self.shortcuts = shortcuts
        label = shortcuts.label
        isDefault = shortcuts.isDefault
        defaultLabel = shortcuts.label(for: shortcuts.defaultShortcut)
        token = NotificationCenter.default.addObserver(forName: ShortcutController.didChange, object: shortcuts, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var message: String {
        switch phase {
        case .rest: "Click the field, then press the keys you want."
        case .recording: "Press the keys you want, or Esc to cancel."
        case .saved: "Saved."
        case .invalid: "Include ⌘ or ⌃."
        case .conflict: "Another app uses this shortcut."
        }
    }

    var isError: Bool { phase == .invalid || phase == .conflict }

    func attach(_ f: ShortcutField) {
        field = f
        f.compact = true
        f.label = label
        f.onRecordingChange = { [weak self] on in
            guard let self else { return }
            if on {
                phase = .recording
                shortcuts.pauseHotKey()
            } else {
                shortcuts.resumeHotKey()
                if phase != .saved { phase = .rest }
            }
            push()
        }
        f.onCandidate = { [weak self] s in
            guard let self else { return }
            if shortcuts.apply(s) {
                phase = .saved
                field?.stopRecording()
            } else {
                phase = .conflict
            }
            refresh()
        }
        f.onNeedsModifier = { [weak self] in self?.phase = .invalid; self?.push() }
        f.onCancel = { [weak self] in
            guard let self, let f = field else { return }
            f.stopRecording()
            phase = .rest
            f.window?.makeFirstResponder(nil)
            push()
        }
    }

    func reset() {
        phase = shortcuts.reset() ? .saved : .conflict
        field?.stopRecording()
        refresh()
    }

    /// The window closed: recording stops and the global shortcut is live again.
    func stop() {
        field?.stopRecording()
        phase = .rest
        push()
    }

    private func refresh() {
        label = shortcuts.label
        isDefault = shortcuts.isDefault
        push()
    }

    private func push() {
        field?.label = label
        field?.phase = phase
    }
}

/// The recorder field itself, hosted in the Settings form.
struct ShortcutRecorderControl: NSViewRepresentable {
    let recorder: ShortcutRecorderModel

    func makeNSView(context: Context) -> ShortcutField {
        let f = ShortcutField()
        recorder.attach(f)
        return f
    }

    func updateNSView(_ f: ShortcutField, context: Context) {
        f.label = recorder.label
        f.phase = recorder.phase
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutField, context: Context) -> CGSize? {
        CGSize(width: 148, height: 24)
    }
}

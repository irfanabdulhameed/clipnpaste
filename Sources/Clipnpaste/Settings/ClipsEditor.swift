import AppKit
import SwiftUI
import ClipnpasteCore

/// The editor for a text clip: a plain-text view, the character count, Cancel (Esc) and Save
/// (⌘Return). Return types a new line, as in any text editor.
struct ClipsEditor: View {
    let clip: Clip
    let save: (String) -> Bool
    let cancel: () -> Void
    @State private var text: String
    @State private var failed = false

    init(clip: Clip, save: @escaping (String) -> Bool, cancel: @escaping () -> Void) {
        self.clip = clip
        self.save = save
        self.cancel = cancel
        _text = State(initialValue: clip.plainText ?? "")
    }

    private var canSave: Bool { !text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: AppIcons.icon(for: clip.sourceBundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text("Edit Text")
                    .font(.headline)
                if let app = clip.sourceAppName {
                    Text("from \(app)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ClipsTextView(text: $text, onSave: commit, onCancel: cancel)
                .frame(minWidth: 480, idealWidth: 520, minHeight: 240, idealHeight: 300)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityLabel("Clip text")
            if failed {
                Label("Couldn't save the change. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack(spacing: 8) {
                Text(text.isEmpty ? "A clip can't be empty." : ClipText.characters(text.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .help("Save (⌘Return)")
            }
        }
        .padding(20)
        .onChange(of: text) { failed = false }
    }

    private func commit() {
        guard canSave else { return }
        failed = !save(text)
    }
}

/// A plain-text NSTextView: no smart quotes or replacements (clips are often code), undo, and
/// its own Esc, ⌘Return and editing shortcuts, so it works with or without an Edit menu.
struct ClipsTextView: NSViewRepresentable {
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let view = ClipsEditingTextView(frame: .zero)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.font = .systemFont(ofSize: 13)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.drawsBackground = true
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.string = text
        view.delegate = context.coordinator
        view.onSave = onSave
        view.onCancel = onCancel
        scroll.documentView = view
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ClipsEditingTextView else { return }
        view.onSave = onSave
        view.onCancel = onCancel
        if view.string != text { view.string = text }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

final class ClipsEditingTextView: NSTextView {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Esc cancels (NSTextView would offer completions).
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command {
            switch key {
            case "\r": onSave?(); return true
            case "a": selectAll(nil); return true
            case "c": copy(nil); return true
            case "x": cut(nil); return true
            case "v": pasteAsPlainText(nil); return true
            case "z": undoManager?.undo(); return true
            case "f":
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                performTextFinderAction(item)
                return true
            default: break
            }
        } else if mods == [.command, .shift], key == "z" {
            undoManager?.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The macOS search field: magnifier, clear button, Esc clears. ↓ moves into the grid.
struct ClipsSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Bumped to put the keyboard in the field (⌘F).
    let focusRequest: Int
    let enabled: Bool
    let onMoveDown: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onMoveDown: onMoveDown) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search clips"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large))
        field.setAccessibilityLabel("Search clips")
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onMoveDown = onMoveDown
        if field.stringValue != text { field.stringValue = text }
        if field.isEnabled != enabled { field.isEnabled = enabled }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onMoveDown: () -> Void
        var focusRequest = 0

        init(text: Binding<String>, onMoveDown: @escaping () -> Void) {
            self.text = text
            self.onMoveDown = onMoveDown
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.moveDown(_:)) {
                onMoveDown()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSSearchField, !field.stringValue.isEmpty {
                field.stringValue = ""
                text.wrappedValue = ""
                return true
            }
            return false
        }
    }
}

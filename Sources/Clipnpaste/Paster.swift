import AppKit
import ApplicationServices
import Carbon
import ClipnpasteCore

/// Writes clips back to the clipboard and sends ⌘V to the app you were in.
@MainActor
enum Paster {
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    private static let promptedKey = "promptedForAccessibility"
    /// Kept alive while it may still be asked for TIFF; replaced by the next write.
    private static var tiffProvider: TIFFProvider?

    /// Writes every stored version of the clip to the general pasteboard.
    /// Returns the pasteboard's new change count, or nil when nothing could be written.
    static func write(_ clip: Clip) -> Int? {
        let item = NSPasteboardItem()
        switch clip.kind {
        case .text:
            guard let text = clip.plainText else { return nil }
            item.setString(text, forType: .string)
            if let rtf = clip.rtfData { item.setData(rtf, forType: .rtf) }
            if let html = clip.htmlData { item.setData(html, forType: .html) }
        case .image:
            guard let url = clip.imageURL, let png = try? Data(contentsOf: url) else { return nil }
            item.setString(url.absoluteString, forType: .fileURL)
            item.setData(png, forType: .png)
            // TIFF of a big photo is large and slow to make, so it is only made if an app asks for it.
            let provider = TIFFProvider(png: png)
            item.setDataProvider(provider, forTypes: [.tiff])
            tiffProvider = provider
        }
        item.setString(Bundle.main.bundleIdentifier ?? "com.irfanabdulhameed.clipnpaste", forType: sourceType)
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.writeObjects([item]) else { return nil }
        return pb.changeCount
    }

    /// Posting keystrokes needs the PostEvent privilege, which System Settings lists under Accessibility.
    static var canPost: Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    /// Shows the system's Accessibility prompt the first time a paste needs it, never again.
    static func promptOnce() {
        guard !UserDefaults.standard.bool(forKey: promptedKey) else { return }
        UserDefaults.standard.set(true, forKey: promptedKey)
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// A password field or a terminal's Secure Keyboard Entry holds Secure Event Input.
    static var secureInputOn: Bool { IsSecureEventInputEnabled() }

    static func postCommandV() {
        let key = vKeyCode()
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// The key that types "v" with ⌘ held in the current layout. Key codes are physical
    /// positions, so Dvorak needs this; "Dvorak – QWERTY ⌘" maps back to the QWERTY key.
    static func vKeyCode() -> CGKeyCode { keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V) }

    static func keyCode(for char: String) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let modifiers = UInt32((cmdKey >> 8) & 0xFF)
        return data.withUnsafeBytes { buf -> CGKeyCode? in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &dead, chars.count, &length, &chars)
                if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == char {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Makes TIFF from the clip's PNG when an app asks for it.
final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let png: Data

    init(png: Data) { self.png = png }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }
}

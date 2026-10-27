import AppKit
import SwiftUI

/// The glass capsule shown when a paste could not be sent: 32 pt tall, centred 24 pt above
/// the visible bottom of the screen, gone after 1.6 s. It never takes the mouse or focus.
@MainActor
final class Toast {
    private static let height: CGFloat = 32
    private static let room: CGFloat = 32
    private static let font = NSFont.systemFont(ofSize: 13)

    private let window: NSPanel
    private let model = ToastModel()
    private let surface: GlassSurface
    private var hideTask: Task<Void, Never>?

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: ToastView(model: model))
        hosting.sizingOptions = []
        surface = GlassSurface(content: hosting, cornerRadius: Self.height / 2, material: .glass)
        let root = NSView()
        root.addSubview(surface)
        window.contentView = root
    }

    /// The capsule's frame on screen.
    var frame: NSRect { window.convertToScreen(surface.frame) }

    func show(_ text: String, on screen: NSScreen?, material: GlassSurface.Material, increaseContrast: Bool) {
        guard let screen = screen ?? NSScreen.main else { return }
        model.text = text
        surface.material = material
        surface.increaseContrast = increaseContrast
        let textWidth = (text as NSString).size(withAttributes: [.font: Self.font]).width
        let w = (textWidth + 32).rounded(.up), h = Self.height
        let vf = screen.visibleFrame
        let x = (vf.midX - w / 2).rounded(.down), y = vf.minY + 24
        window.setFrame(NSRect(x: x - Self.room, y: y - Self.room, width: w + 2 * Self.room, height: h + 2 * Self.room), display: false)
        surface.frame = NSRect(x: Self.room, y: Self.room, width: w, height: h)
        window.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.window.orderOut(nil)
        }
    }
}

@MainActor @Observable
final class ToastModel {
    var text = ""
}

struct ToastView: View {
    let model: ToastModel

    var body: some View {
        Text(model.text)
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: Palette.label))
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

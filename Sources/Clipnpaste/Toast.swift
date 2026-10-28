import AppKit
import SwiftUI

/// The glass capsule shown when a paste could not be sent: 32 pt tall, centred 24 pt above
/// the visible bottom of the screen, gone after 1.6 s. It never takes the mouse or focus.
///
/// Motion (plan, Panel table): born blurred on `quick`: its text 12 → 0 pt blur, the capsule
/// 1.06 → 1, opacity 0 → 1 on `fadeIn` 140 ms. After 1.6 s it leaves on `leave` 160 ms: opacity
/// → 0, text blur → 8 pt. The glass itself is never blurred (a backdrop-sampling layer is the
/// costliest thing to filter), so the blur lives on the text. Reduce Motion: a 120 ms fade in
/// and out, nothing else.
@MainActor
final class Toast {
    private static let height: CGFloat = 32
    private static let room: CGFloat = 32
    private static let font = NSFont.systemFont(ofSize: 13)
    /// How long it stays before leaving.
    static let holdMs = 1600.0

    private let window: NSPanel
    private let model = ToastModel()
    private let hosting: NSHostingView<ToastView>
    private let surface: GlassSurface
    private var hideTask: Task<Void, Never>?
    private(set) lazy var fx = Fx { [unowned self] fx in self.render(fx) }
    /// Shown, or leaving; false once ordered out.
    private(set) var isShown = false

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
        hosting = NSHostingView(rootView: ToastView(model: model))
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layerUsesCoreImageFilters = true
        surface = GlassSurface(content: hosting, cornerRadius: Self.height / 2, material: .glass)
        let root = NSView()
        root.wantsLayer = true
        root.addSubview(surface)
        window.contentView = root
    }

    /// The capsule's frame on screen.
    var frame: NSRect { window.convertToScreen(surface.frame) }
    var isVisible: Bool { window.isVisible }
    /// The text's blur filter, for the checks.
    var textHasFilter: Bool { hosting.layer?.filters?.isEmpty == false }

    /// `above`: a frame on screen the capsule sits 12 pt above (the open panel), instead of the
    /// bottom of the screen.
    func show(_ text: String, on screen: NSScreen?, material: GlassSurface.Material, increaseContrast: Bool,
              above: NSRect? = nil) {
        guard let screen = screen ?? NSScreen.main else { return }
        model.text = text
        surface.material = material
        surface.increaseContrast = increaseContrast
        let textWidth = (text as NSString).size(withAttributes: [.font: Self.font]).width
        let w = (textWidth + 32).rounded(.up), h = Self.height
        let vf = screen.visibleFrame
        let x = (vf.midX - w / 2).rounded(.down), y = above.map { ($0.maxY + 12).rounded() } ?? vf.minY + 24
        window.setFrame(NSRect(x: x - Self.room, y: y - Self.room, width: w + 2 * Self.room, height: h + 2 * Self.room), display: false)
        surface.frame = NSRect(x: Self.room, y: Self.room, width: w, height: h)
        if Motion.reduce {
            fx.blur.set(0)
            fx.scale.set(1)
            fx.op.set(0)
            fx.op.tween(to: 1, ms: 120)
        } else {
            fx.blur.set(12)
            fx.blur.spring(to: 0, duration: Motion.quick)
            fx.scale.set(1.06)
            fx.scale.spring(to: 1, duration: Motion.quick)
            fx.op.set(0)
            fx.op.tween(to: 1, ms: 140, ease: Motion.fadeIn)
        }
        // The from-state is drawn before the window shows.
        MotionClock.shared.flush()
        isShown = true
        window.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.holdMs)))
            guard !Task.isCancelled else { return }
            self?.leave()
        }
    }

    private func leave() {
        let gone: () -> Void = { [weak self] in
            guard let self, self.fx.op.v <= 0.001 else { return }
            self.window.orderOut(nil)
            self.isShown = false
            self.fx.reset()
        }
        if Motion.reduce {
            fx.op.tween(to: 0, ms: 120, done: gone)
        } else {
            fx.op.tween(to: 0, ms: 160, ease: Motion.leave, done: gone)
            fx.blur.tween(to: 8, ms: 160, ease: Motion.leave)
        }
    }

    private func render(_ fx: Fx) {
        LayerLook.opacity(surface.layer, fx.op.v)
        LayerLook.scale(surface, fx.scale.v)
        LayerLook.blur(hosting.layer, fx.blur.v)
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

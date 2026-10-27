import AppKit

/// The panel's window: borderless and non-activating, so the app you are in stays active,
/// yet able to become key so it gets the arrow keys. Level `.screenSaver` and these
/// collection behaviours keep it above full-screen apps and on every Space.
final class ClipPanel: NSPanel {
    /// Sees every event first. Returns the event to deliver (possibly changed), or nil when handled.
    var router: ((NSEvent) -> NSEvent?)?
    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        guard let router else { return super.sendEvent(event) }
        if let e = router(event) { super.sendEvent(e) }
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    // Esc is handled by the router.
    override func cancelOperation(_ sender: Any?) {}
}

/// The window's content view. Reports the pointer from anywhere in the window, even
/// though the app is never active.
final class PanelRootView: NSView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { onMouseMoved?(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}

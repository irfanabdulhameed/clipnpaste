import AppKit
import SwiftUI
import ClipnpasteCore

/// One step's page: the picture, the title, one or two sentences, and the step's own control.
@MainActor @Observable
final class WelcomePageModel {
    let step: WelcomeStep
    var theme: Theme
    private(set) var context: StageContext
    /// The loop plays only while the page is current and the window is on screen.
    var running = false
    /// Reduce Motion: the picture stands on its key frame.
    var still = false
    /// Offscreen renders: a fixed loop time.
    var frozen: Double?
    @ObservationIgnored let start = Date()

    var shortcutLabel: String {
        didSet { if shortcutLabel != oldValue { rebuildContext() } }
    }

    // The Accessibility step.
    var axGranted = false

    // The shortcut step.
    var recorderPhase: RecorderPhase = .rest
    var pendingLabel: String?
    @ObservationIgnored let field = ShortcutField()
    @ObservationIgnored var openAccessibility: () -> Void = {}

    init(step: WelcomeStep, theme: Theme, shortcutLabel: String) {
        self.step = step
        self.theme = theme
        self.shortcutLabel = shortcutLabel
        context = WelcomeDemo.context(theme: theme, shortcutKeys: KeySpeech.keys(shortcutLabel), look: CardLook())
    }

    func setTheme(_ t: Theme) {
        guard t.increaseContrast != theme.increaseContrast || t.reduceTransparency != theme.reduceTransparency
            || t.reduceMotion != theme.reduceMotion else { return }
        theme = t
        rebuildContext()
    }

    private func rebuildContext() {
        let old = context
        context = StageContext(theme: theme, now: old.now, clips: old.clips, photos: old.photos,
                               shortcutKeys: KeySpeech.keys(shortcutLabel), geometry: old.geometry, look: old.look)
    }

    /// The loop time for a frame drawn at `date`.
    func time(at date: Date) -> Double {
        let timing = VignetteTiming.of(step)
        if let frozen { return frozen }
        if still || timing.period <= 0 { return timing.still }
        let t = date.timeIntervalSince(start) / MotionClock.shared.timeScale
        return t.truncatingRemainder(dividingBy: timing.period)
    }

    /// The keys the recorder shows: what was just pressed, or the saved shortcut.
    var recorderKeys: [String] { KeySpeech.keys(pendingLabel ?? shortcutLabel) }

    var recorderMessage: String {
        switch recorderPhase {
        case .recording: return "Press the keys you want, or Esc to cancel."
        case .invalid: return "Include ⌘ or ⌃."
        case .conflict: return "Another app uses this shortcut. Try another."
        case .saved: return "Saved."
        case .rest:
            if let pendingLabel { return "Press Confirm to use \(pendingLabel)." }
            return "Click the field, then press the keys you want."
        }
    }

    var recorderIsError: Bool { recorderPhase == .invalid || recorderPhase == .conflict }
}

/// The page itself, 480 wide: stage, title, body, then the step's accessory.
struct WelcomePageView: View {
    let model: WelcomePageModel

    var body: some View {
        let theme = model.theme
        let step = model.step
        VStack(alignment: .leading, spacing: 0) {
            WelcomeStageFrame(theme: theme) {
                if step == .chooseShortcut {
                    RecorderStage(model: model)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !model.running || model.still || model.frozen != nil)) { tl in
                        WelcomeVignette(step: step, t: model.time(at: tl.date), c: model.context)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(step.visualDescription)
                    .accessibilityAddTraits(.isImage)
                }
            }
            Text(step.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.label)
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)
            Text(step.body(shortcut: model.shortcutLabel))
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(theme.label2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            accessory
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .frame(width: StageGeo.size.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var accessory: some View {
        if let keys = model.step.legend {
            HStack(spacing: 5) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, k in Keycap(label: k, theme: model.theme) }
            }
            .accessibilityElement(children: .combine)
        } else if model.step == .accessibility {
            AccessibilityStatus(model: model)
        }
    }
}

/// The live permission state and the way to System Settings. Turning green is a one-frame flip
/// with a small pop.
private struct AccessibilityStatus: View {
    let model: WelcomePageModel

    var body: some View {
        let granted = model.axGranted
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                } else {
                    Circle().fill(model.theme.amber).frame(width: 7, height: 7).frame(width: 13)
                }
                Text(granted ? "Allowed. Return pastes for you." : "Not allowed yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(granted ? model.theme.label : model.theme.label2)
            }
            .modifier(PopOnChange(trigger: granted, peak: Motion.popPeak, anchor: .leading))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(granted ? "Accessibility allowed" : "Accessibility not allowed yet")
            Spacer(minLength: 0)
            if !granted {
                WelcomeButtonControl(title: "Open Settings", style: .secondary) { model.openAccessibility() }
                    .help("Open Accessibility in System Settings")
            }
        }
        .frame(height: WelcomeButton.height)
    }
}

/// The shortcut step's stage: the recorder field (it pops when a new combination lands) and its message.
private struct RecorderStage: View {
    let model: WelcomePageModel

    var body: some View {
        let theme = model.theme
        VStack(spacing: 14) {
            Text("Shortcut")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.label2)
                .accessibilityHidden(true)
            FieldHost(field: model.field)
                .frame(width: 280, height: 52)
            Text(model.recorderMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.recorderIsError ? Color(nsColor: RecorderPalette.error) : theme.label3)
                .lineLimit(1)
        }
        .frame(width: StageGeo.size.width, height: StageGeo.size.height)
    }
}

/// The recorder's error red, the same pair as the recorder window's.
enum RecorderPalette {
    static let error = Palette.pair(NSColor(srgbRed: 0.70, green: 0.15, blue: 0.12, alpha: 1),
                                    NSColor(srgbRed: 1.0, green: 0.61, blue: 0.58, alpha: 1))
}

private struct FieldHost: NSViewRepresentable {
    let field: ShortcutField
    func makeNSView(context: Context) -> ShortcutField { field }
    func updateNSView(_ nsView: ShortcutField, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutField, context: Context) -> CGSize? {
        CGSize(width: 280, height: 52)
    }
}

/// A one-frame state change's small pop when `trigger` changes: up 60 ms on popUp, back 140 ms
/// on popDown. None under Reduce Motion.
struct PopOnChange<T: Equatable & Sendable>: ViewModifier {
    let trigger: T
    var peak = Motion.popPeak
    var anchor: UnitPoint = .center

    func body(content: Content) -> some View {
        let p: Double = Motion.reduce ? 1 : peak
        let k = MotionClock.shared.timeScale
        let up = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0), endControlPoint: UnitPoint(x: 0, y: 1))
        let down = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.333, y: 0), endControlPoint: UnitPoint(x: 0, y: 1))
        content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, s in
            view.scaleEffect(s, anchor: anchor)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(p, duration: 0.06 * k, timingCurve: up)
                LinearKeyframe(1.0, duration: 0.14 * k, timingCurve: down)
            }
        }
    }
}

import SwiftUI
import ClipnpasteCore

/// "Return copies only." with a way to fix it.
struct AccessibilityBanner: View {
    let theme: Theme
    let open: () -> Void

    var body: some View {
        Banner(theme: theme, text: "Return copies only. Allow Clipnpaste in Accessibility to paste.", open: open)
    }
}

/// Pasteboard privacy set to ask or deny.
struct PasteboardBanner: View {
    let theme: Theme
    let open: () -> Void

    var body: some View {
        Banner(theme: theme, text: "macOS asks before Clipnpaste reads copies. Set it to Allow.", open: open)
    }
}

/// A top-bar banner: an amber dot, one line, "Open Settings". It flips in and out in one frame
/// (no fade); as it appears its dot pops 1 → 1.08 → 1.
struct Banner: View {
    let theme: Theme
    let text: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            BannerDot(color: theme.amber, reduceMotion: theme.reduceMotion)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(theme.label)
                .lineLimit(1)
                .truncationMode(.tail)
            Button("Open Settings", action: open)
                .buttonStyle(BannerButtonStyle(theme: theme))
                .fixedSize()
        }
    }
}

/// The 6 pt dot. The `pop` token: 60 ms up on popUp, 140 ms back on popDown, three keys.
/// Under Reduce Motion it only flips in.
struct BannerDot: View {
    let color: Color
    let reduceMotion: Bool
    @State private var scale: CGFloat = 1

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .scaleEffect(scale)
            .onAppear {
                guard !reduceMotion else { return }
                let up = Motion.popUp, down = Motion.popDown
                // SwiftUI runs this one, not the motion clock, so `--slow-motion` is applied here.
                let k = DebugFlags.slowMotion
                withAnimation(.timingCurve(up.x1, up.y1, up.x2, up.y2, duration: 0.06 * k)) {
                    scale = Motion.popPeak
                } completion: {
                    withAnimation(.timingCurve(down.x1, down.y1, down.x2, down.y2, duration: 0.14 * k)) { scale = 1 }
                }
            }
    }
}

struct BannerButtonStyle: ButtonStyle {
    let theme: Theme
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.label)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(configuration.isPressed ? theme.buttonPress : hovered ? theme.buttonHover : theme.button))
            .onHover { hovered = $0 }
    }
}

/// First use: nothing copied yet.
struct EmptyRow: View {
    let theme: Theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(theme.label3)
            Text("Copy something and it shows up here.")
                .font(.system(size: 12))
                .foregroundStyle(theme.label2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI
import ClipnpasteCore

/// "Return copies only." with a way to fix it.
struct AccessibilityBanner: View {
    let theme: Theme
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(theme.amber).frame(width: 6, height: 6)
            Text("Return copies only. Allow Clipnpaste in Accessibility to paste.")
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

import SwiftUI
import ClipnpasteCore

/// The panel's content inside the glass: top bar, then the row of cards or the empty state.
struct PanelView: View {
    @Bindable var model: PanelModel

    var body: some View {
        let g = model.geometry
        let theme = model.theme
        ZStack(alignment: .topLeading) {
            if model.clips.isEmpty {
                EmptyRow(theme: theme)
                    .frame(width: CGFloat(g.width), height: CGFloat(g.cardHeight))
                    .offset(y: CGFloat(g.cardTop))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: CGFloat(CardLayout.gap)) {
                        ForEach(Array(model.clips.enumerated()), id: \.element.id) { i, clip in
                            CardView(clip: clip, state: model.state(for: clip.id), geometry: g, theme: theme,
                                     now: model.now, onMissing: { model.markMissing($0) })
                                .modifier(FrameLog(enabled: DebugFlags.logGeometry && i < 3, name: "card \(i)"))
                        }
                    }
                    .padding(.horizontal, CGFloat(g.sidePadding))
                    .padding(.top, CGFloat(PanelGeometry.contentTop))
                    .padding(.bottom, CGFloat(CardLayout.bottomPadding))
                }
                .scrollIndicators(.never)
                .scrollPosition($model.scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                    model.scrolled(to: x)
                }
                .frame(width: CGFloat(g.width), height: CGFloat(g.height - PanelGeometry.scrollTop))
                .offset(y: CGFloat(PanelGeometry.scrollTop))
            }
            TopBar(model: model, theme: theme)
                .frame(width: CGFloat(g.width), height: CGFloat(CardLayout.topBar))
        }
        .frame(width: CGFloat(g.width), height: CGFloat(g.height), alignment: .topLeading)
        .clipShape(.rect(cornerRadius: PanelGeometry.radius, style: .continuous))
    }
}

/// 28 pt: the status slot on the left, the resize pill in the centre, History on the right.
struct TopBar: View {
    let model: PanelModel
    let theme: Theme

    var body: some View {
        let g = model.geometry
        let empty = model.clips.isEmpty
        ZStack(alignment: .topLeading) {
            if model.needsAccessibility {
                AccessibilityBanner(theme: theme) { model.onOpenSettings?() }
                    .frame(maxWidth: CGFloat(g.width) / 2 - 76, alignment: .leading)
                    .frame(height: CGFloat(CardLayout.topBar))
                    .padding(.leading, 14)
            }
            // The pill and History are drawn at rest only; their drag and history mode come with the grid.
            if g.canGrow && !empty {
                Capsule()
                    .fill(theme.pill)
                    .frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .help("Drag to resize")
            }
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.label2)
                .frame(width: 22, height: 22)
                .opacity(empty ? 0.45 : 1)
                .help("History (⌘Y)")
                .accessibilityLabel("History")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 3)
                .padding(.trailing, 12)
        }
    }
}

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

/// Logs a view's frame in the panel, for the geometry check (`--show-panel`).
struct FrameLog: ViewModifier {
    let enabled: Bool
    let name: String

    func body(content: Content) -> some View {
        if enabled {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
                debugLog("\(name) frame in panel: x \(r.minX) y \(r.minY) w \(r.width) h \(r.height)")
            }
        } else {
            content
        }
    }
}

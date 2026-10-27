import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClipnpasteCore

/// Builds the clip store and the clipboard watcher. The only file that knows which ones the app uses.
@MainActor
struct AppEnvironment {
    let store: any ClipStore
    let watcher: any ClipboardWatcher

    static func make() throws -> AppEnvironment {
        // Any debug or demo flag keeps the in-memory store and no watcher, so checks never
        // touch the real history or clipboard.
        if DebugFlags.usesDemoStore {
            let store = InMemoryClipStore(clips: DebugFlags.empty ? [] : DemoClips.make())
            if DebugFlags.demoExtra { DemoExtras.add(to: store) }
            let watcher = NoOpWatcher()
            watcher.start()
            return AppEnvironment(store: store, watcher: watcher)
        }
        let store = try SQLiteClipStore(directory: SQLiteClipStore.defaultDirectory)
        let watcher = PasteboardWatcher(store: store)
        watcher.start()
        return AppEnvironment(store: store, watcher: watcher)
    }

    /// Used when the store cannot be opened, so the panel still works for this session.
    static func fallback() -> AppEnvironment {
        AppEnvironment(store: InMemoryClipStore(), watcher: NoOpWatcher())
    }
}

/// Stands in for the capture stream's watcher until the merge.
@MainActor
final class NoOpWatcher: ClipboardWatcher {
    var onClip: (@MainActor (Clip) -> Void)?
    func start() {}
    func stop() {}
    func markOwnWrite(changeCount: Int) {}
}

/// `--demo-extra`: image cards (landscape with a thumbnail, phone screenshot, transparent PNG,
/// a missing file), a long text and short stress texts, written to a temporary folder that is
/// deleted at quit. For the in-memory demo store only.
@MainActor
enum DemoExtras {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClipnpasteDemo", isDirectory: true)

    static func add(to store: any ClipStore) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var clips: [Clip] = []
        if let url = png("dusk", 1920, 1080, alpha: false, draw: dusk) {
            let thumb = png("dusk-thumb", 640, 360, alpha: false, draw: dusk)
            clips.append(image(url, thumb: thumb, 1920, 1080, app: ("com.apple.Photos", "Photos")))
        }
        clips.append(text(long, app: ("com.apple.Notes", "Notes")))
        if let url = png("badge", 600, 600, alpha: true, draw: badge) {
            clips.append(image(url, thumb: nil, 600, 600, app: ("com.figma.Desktop", "Figma")))
        }
        if let url = png("phone", 1170, 2532, alpha: false, draw: phone) {
            clips.append(image(url, thumb: nil, 1170, 2532, app: ("com.apple.ScreenContinuity", "iPhone")))
        }
        clips.append(image(folder.appendingPathComponent("gone.png"), thumb: nil, 800, 600, app: ("com.apple.finder", "Finder")))
        clips.append(text("A", app: ("com.apple.MobileSMS", "Messages")))
        clips.append(text("مرحبا بالعالم 👋🏽 See you at 4:30 🙂", app: ("com.apple.MobileSMS", "Messages")))
        let now = Date()
        for (i, clip) in clips.enumerated().reversed() {
            var c = clip
            c.createdAt = now.addingTimeInterval(-Double(i) * 25 - 10)
            store.insertOrBump(c)
        }
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func text(_ s: String, app: (String, String)) -> Clip {
        Clip(kind: .text, plainText: s, sourceBundleID: app.0, sourceAppName: app.1, contentHash: DemoClips.hash(s))
    }

    private static func image(_ url: URL, thumb: URL?, _ w: Int, _ h: Int, app: (String, String)) -> Clip {
        Clip(kind: .image, imageURL: url, thumbnailURL: thumb, pixelWidth: w, pixelHeight: h,
             sourceBundleID: app.0, sourceAppName: app.1, contentHash: DemoClips.hash(url.path))
    }

    private static func png(_ name: String, _ w: Int, _ h: Int, alpha: Bool,
                            draw: (CGContext, CGFloat, CGFloat) -> Void) -> URL? {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info.rawValue) else { return nil }
        draw(ctx, CGFloat(w), CGFloat(h))
        let url = folder.appendingPathComponent("\(name).png")
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    private static func gradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) {
            ctx.drawLinearGradient(g, start: from, end: to, options: [])
        }
    }

    /// A dusk sky over two ridges.
    private static func dusk(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
        gradient(ctx, [rgb(0xF6B26B), rgb(0xC9668A), rgb(0x3B3F7A)], from: .zero, to: CGPoint(x: 0, y: h))
        ctx.setFillColor(rgb(0xFFE3B0, 0.9))
        ctx.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.30, width: h * 0.16, height: h * 0.16))
        for (base, amp, color) in [(0.42, 0.10, rgb(0x5A3E68)), (0.26, 0.08, rgb(0x2B2440))] {
            ctx.beginPath()
            ctx.move(to: .zero)
            for i in 0...64 {
                let t = CGFloat(i) / 64
                ctx.addLine(to: CGPoint(x: t * w, y: h * (base + amp * sin(t * 7 + base * 9) * 0.6 + amp * 0.4 * sin(t * 19))))
            }
            ctx.addLine(to: CGPoint(x: w, y: 0))
            ctx.closePath()
            ctx.setFillColor(color)
            ctx.fillPath()
        }
    }

    /// A round badge on a transparent background.
    private static func badge(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
        let r = CGRect(x: w * 0.12, y: h * 0.12, width: w * 0.76, height: h * 0.76)
        ctx.addEllipse(in: r)
        ctx.clip()
        gradient(ctx, [rgb(0x34C3FF), rgb(0x1F6FEB)], from: CGPoint(x: 0, y: h), to: .zero)
        ctx.resetClip()
        ctx.setFillColor(rgb(0xFFFFFF, 0.92))
        ctx.fill(CGRect(x: w * 0.30, y: h * 0.46, width: w * 0.40, height: h * 0.08))
        ctx.fill(CGRect(x: w * 0.46, y: h * 0.30, width: w * 0.08, height: h * 0.40))
    }

    /// A chat-like phone screenshot.
    private static func phone(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
        ctx.setFillColor(rgb(0xF2F2F7))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fill(CGRect(x: 0, y: h - 300, width: w, height: 300))
        var y = h - 420
        for i in 0..<9 {
            let mine = i % 3 == 1
            let bw = w * (0.45 + 0.08 * CGFloat(i % 4))
            let bh: CGFloat = i % 2 == 0 ? 120 : 180
            let x = mine ? w - bw - 48 : 48
            ctx.setFillColor(mine ? rgb(0x0A84FF) : rgb(0xE5E5EA))
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y - bh, width: bw, height: bh), cornerWidth: 54, cornerHeight: 54, transform: nil))
            ctx.fillPath()
            y -= bh + 40
        }
    }

    private static let long = "Notes from the Thursday review. The opening shot holds too long before the first move, so trim eight frames from the head and let the panel arrive while the music is still rising. Keep the blur-in on the cards but tighten the stagger; at the current spacing the last card lands after the downbeat and the row reads as late. The colour pass is close. The blue in the end card should match the product exactly, so pull it from the brand file rather than picking it from the render. Sound: one click per keystroke in the typing section and a soft thump when the panel lands, nothing louder than the voice. Export a 60 fps master and a 30 fps cut for socials, both at 1920 by 1080, and name the files with the date first so they sort properly."
}

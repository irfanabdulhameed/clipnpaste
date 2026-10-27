// Renders the three menu bar icon designs side by side so they can be compared at true pixels:
// each on a light and a dark menu bar beside system icons, closed and with the menu open, at 1×
// and 2×, plus the 1× pixels at 8× and the 2× pixels at 4× on a pixel grid.
//
//   swiftc -parse-as-library -o /tmp/menubar-options scripts/menubar-options.swift Sources/ClipnpasteCore/MenuBarGlyph.swift
//   /tmp/menubar-options reports/menubar-options        writes compare.png there
import AppKit

@main
enum MenuBarOptions {
    static func main() {
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "reports/menubar-options"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("compare.png")
        try! Sheet().render().representation(using: .png, properties: [:])!.write(to: url)
        print("Wrote \(url.path)")
    }
}

// MARK: - Colours

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

struct Bar {
    let background: NSColor
    let ink: NSColor
    let highlight: NSColor
}

let lightBar = Bar(background: rgb(0xE9E9EE), ink: NSColor(white: 0, alpha: 0.85), highlight: NSColor(white: 0, alpha: 0.1))
let darkBar = Bar(background: rgb(0x1E1E21), ink: NSColor(white: 1, alpha: 0.9), highlight: NSColor(white: 1, alpha: 0.18))
let page = rgb(0xF5F5F7), text = rgb(0x1D1D1F), secondary = rgb(0x6E6E73), accent = rgb(0x0A84FF)

// MARK: - Drawing

/// A bitmap in points at `scale` pixels per point, drawn with y down.
func canvas(width: Int, height: Int, scale: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    // The context already maps the rep's points to its pixels; only flip it.
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    g.cgContext.translateBy(x: 0, y: CGFloat(height))
    g.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: g.cgContext, flipped: true)
    NSGraphicsContext.current?.imageInterpolation = .none
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// A template image tinted as the menu bar tints it, its pixels picked by AppKit for the context.
func drawTemplate(_ image: NSImage, at origin: NSPoint, ink: NSColor) {
    let size = image.size
    let tinted = NSImage(size: size, flipped: false) { r in
        image.draw(in: r)
        ink.set()
        r.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
}

/// An SF Symbol at its own menu bar size, centred on `centerY` and placed on whole points.
func symbol(_ name: String, x: CGFloat, centerY: CGFloat, ink: NSColor) {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
    img.isTemplate = true
    drawTemplate(img, at: NSPoint(x: x, y: (centerY - img.size.height / 2).rounded()), ink: ink)
}

func label(_ s: String, _ p: NSPoint, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = text) {
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

/// A menu bar strip in points: Wi-Fi, Spotlight, the icon, Control Center, then the icon again with
/// its menu open.
let stripWidth = 168, stripHeight = 24
func strip(_ icon: NSImage, bar: Bar, scale: Int) -> NSBitmapImageRep {
    canvas(width: stripWidth, height: stripHeight, scale: scale) {
        bar.background.setFill()
        NSRect(x: 0, y: 0, width: stripWidth, height: stripHeight).fill()
        let mid = CGFloat(stripHeight) / 2
        symbol("wifi", x: 10, centerY: mid, ink: bar.ink)
        symbol("magnifyingglass", x: 42, centerY: mid, ink: bar.ink)
        let iconY = ((CGFloat(stripHeight) - icon.size.height) / 2).rounded()
        drawTemplate(icon, at: NSPoint(x: 70, y: iconY), ink: bar.ink)
        symbol("switch.2", x: 100, centerY: mid, ink: bar.ink)
        // Menu open: the status button's highlight behind the same icon.
        bar.highlight.setFill()
        NSBezierPath(roundedRect: NSRect(x: 132, y: 2, width: 28, height: 20), xRadius: 6, yRadius: 6).fill()
        drawTemplate(icon, at: NSPoint(x: 137, y: iconY), ink: bar.ink)
    }
}

/// Pixels of `rep` enlarged `k` times on a faint pixel grid.
func enlarged(_ rep: NSBitmapImageRep, k: Int, at o: NSPoint) {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    NSColor.white.setFill()
    NSRect(x: o.x, y: o.y, width: CGFloat(w * k), height: CGFloat(h * k)).fill()
    for y in 0..<h {
        for x in 0..<w {
            let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
            guard a > 0 else { continue }
            NSColor(white: 0, alpha: 0.85 * a).setFill()
            NSRect(x: o.x + CGFloat(x * k), y: o.y + CGFloat(y * k), width: CGFloat(k), height: CGFloat(k)).fill(using: .sourceOver)
        }
    }
    rgb(0x0A84FF, 0.12).setFill()
    for x in 0...w { NSRect(x: o.x + CGFloat(x * k), y: o.y, width: 1, height: CGFloat(h * k)).fill(using: .sourceOver) }
    for y in 0...h { NSRect(x: o.x, y: o.y + CGFloat(y * k), width: CGFloat(w * k), height: 1).fill(using: .sourceOver) }
}

func place(_ rep: NSBitmapImageRep, at p: NSPoint) {
    rep.draw(in: NSRect(x: p.x, y: p.y, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)),
             from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
}

// MARK: - Sheet

struct Sheet {
    let designs = [1, 2, 3]
    let blurbs = [
        1: "A card tilting up off the stack,\nas in the app icon.",
        2: "The panel at the bottom of the\nscreen, holding a row of cards.",
        3: "One card inside the selection\nring, its source-app tile cut out.",
    ]
    let left: CGFloat = 32, col1: CGFloat = 236, col2: CGFloat = 436, col3: CGFloat = 800, col4: CGFloat = 984
    let rowHeight: CGFloat = 168, top: CGFloat = 92

    func render() -> NSBitmapImageRep {
        let width = 1172, height = Int(top + rowHeight * CGFloat(designs.count + 1)) + 8
        return canvas(width: width, height: height, scale: 1) {
            page.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            label("Clipnpaste menu bar icon", NSPoint(x: left, y: 24), size: 17, weight: .semibold)
            label("Template images: macOS tints them for every menu bar. Every pixel shown 1:1 unless marked.",
                  NSPoint(x: left, y: 48), color: secondary)
            for (x, title) in [(col1, "1× (external displays)"), (col2, "2× (Retina)"), (col3, "1× pixels × 8"), (col4, "2× pixels × 4")] {
                label(title, NSPoint(x: x, y: top - 22), size: 11, weight: .medium, color: secondary)
            }
            for (i, d) in designs.enumerated() {
                row(MenuBarGlyph.image(d), y: top + CGFloat(i) * rowHeight, design: d)
            }
            // The icon it replaces, for reference.
            if let old = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) {
                old.isTemplate = true
                row(old, y: top + CGFloat(designs.count) * rowHeight, design: nil)
            }
        }
    }

    func row(_ icon: NSImage, y: CGFloat, design: Int?) {
        if let d = design {
            label("\(d)  \(MenuBarGlyph.names[d]!)", NSPoint(x: left, y: y), size: 15, weight: .semibold)
            label(blurbs[d]!, NSPoint(x: left, y: y + 24), color: secondary)
            if d == MenuBarGlyph.chosen { label("In the menu bar", NSPoint(x: left, y: y + 64), weight: .medium, color: accent) }
        } else {
            label("Before", NSPoint(x: left, y: y), size: 15, weight: .semibold)
            label("SF Symbol doc.on.clipboard.", NSPoint(x: left, y: y + 24), color: secondary)
        }
        place(strip(icon, bar: lightBar, scale: 1), at: NSPoint(x: col1, y: y))
        place(strip(icon, bar: darkBar, scale: 1), at: NSPoint(x: col1, y: y + 32))
        place(strip(icon, bar: lightBar, scale: 2), at: NSPoint(x: col2, y: y))
        place(strip(icon, bar: darkBar, scale: 2), at: NSPoint(x: col2, y: y + 56))
        if let d = design {
            enlarged(MenuBarGlyph.bitmap(d, scale: 1), k: 8, at: NSPoint(x: col3, y: y))
            enlarged(MenuBarGlyph.bitmap(d, scale: 2), k: 4, at: NSPoint(x: col4, y: y))
        }
    }
}

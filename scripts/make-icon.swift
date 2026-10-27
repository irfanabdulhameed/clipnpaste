// Draws Clipnpaste's app icon in code. Each size is drawn for its size, so 16 px stays crisp.
// Three designs, all on the macOS icon grid (an 824 pt rounded square with continuous corners
// on a 1024 pt canvas, the shape macOS 26 keeps without adding its grey frame):
//   1  Shelf  the glass panel rising from the bottom edge, its middle card picked
//   2  Lift   the picked card tilting up and off the stack, as it does when dragged out
//   3  Clip   a card held by a clip
//
//   swift scripts/make-icon.swift                 writes Resources/AppIcon.icns from the default design
//   swift scripts/make-icon.swift 3               writes it from design 3 (or 1, or 2)
//   swift scripts/make-icon.swift --compare DIR   renders all three into DIR to compare them:
//                                                 option-1.png ... option-3.png and compare.png
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SwiftUI

let defaultDesign = 2
let names = [1: "Shelf", 2: "Lift", 3: "Clip"]

// MARK: - Colour and shape

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha,
    ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

let white = 0xFFFFFF as UInt32, black = 0x000000 as UInt32
/// The prototype's accent (system blue).
let accent = 0x0A84FF as UInt32

/// Apple's continuous corners, the curve the system uses for icons, windows and the panel.
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func rounded(_ rect: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
    UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                           topTrailingRadius: top, style: .continuous).path(in: rect).cgPath
}

func capsule(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
}

func box(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
}

// MARK: - Pen

/// Draws on a 1024-unit canvas with y pointing down, at any pixel size.
struct Pen {
    let ctx: CGContext
    /// Pixels per canvas unit.
    let k: CGFloat
    /// 16 and 32 px: fewer, bolder parts.
    let tiny: Bool
    /// One pixel, in canvas units.
    var pixel: CGFloat { 1 / k }

    func layer(_ draw: () -> Void) {
        ctx.saveGState()
        draw()
        ctx.restoreGState()
    }

    /// Shadow offsets and blurs are in pixels, so they are scaled here.
    func shadow(y: CGFloat, blur: CGFloat, _ c: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: -y * k), blur: blur * k, color: c)
    }

    func clip(_ path: CGPath) {
        ctx.addPath(path)
        ctx.clip()
    }

    func fill(_ path: CGPath, _ c: CGColor) {
        ctx.addPath(path)
        ctx.setFillColor(c)
        ctx.fillPath()
    }

    func fill(_ path: CGPath, _ g: CGGradient, _ from: CGPoint, _ to: CGPoint) {
        layer {
            clip(path)
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// A soft pool of colour that fades to nothing at `radius`.
    func glow(_ center: CGPoint, _ radius: CGFloat, _ c: CGColor) {
        ctx.drawRadialGradient(gradient([(0, c), (1, c.copy(alpha: 0)!)]), startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
    }

    func stroke(_ path: CGPath, _ width: CGFloat, _ c: CGColor) {
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(c)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// A light edge just inside `path`, coloured top to bottom by `g`.
    func rim(_ path: CGPath, _ width: CGFloat, _ g: CGGradient, top: CGFloat, bottom: CGFloat) {
        layer {
            clip(path)
            ctx.addPath(path)
            ctx.setLineWidth(width * 2)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
        }
    }

    /// Runs `draw` turned by `degrees` around `center`.
    func turned(_ degrees: CGFloat, around center: CGPoint, _ draw: () -> Void) {
        layer {
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: degrees * .pi / 180)
            ctx.translateBy(x: -center.x, y: -center.y)
            draw()
        }
    }
}

// MARK: - Shared parts

/// The glass rim: bright at the top, gone through the middle, a little light at the bottom.
let glassRim = gradient([(0, color(white, 0.95)), (0.32, color(white, 0.25)), (0.58, color(white, 0)), (1, color(white, 0.5))])

/// A source-app tile, like the 16 pt icon in a card's header.
func appTile(_ p: Pen, _ r: CGRect, _ top: UInt32, _ bottom: UInt32) {
    let path = rounded(r, r.width * 0.28)
    p.fill(path, gradient([(0, color(top)), (1, color(bottom))]), CGPoint(x: 0, y: r.minY), CGPoint(x: 0, y: r.maxY))
}

/// Card header: the source-app tile and the time, as in the panel.
/// Returns the y where the body starts.
@discardableResult
func header(_ p: Pen, _ card: CGRect, tile: (UInt32, UInt32)) -> CGFloat {
    let pad = card.height * 0.075
    let side = card.height * 0.12
    let tileRect = CGRect(x: card.minX + pad, y: card.minY + pad, width: side, height: side)
    appTile(p, tileRect, tile.0, tile.1)
    let t = side * 0.34
    p.fill(capsule(CGRect(x: tileRect.maxX + side * 0.42, y: tileRect.midY - t / 2, width: card.width * 0.16, height: t)),
           color(black, 0.16))
    return tileRect.maxY + pad * 0.9
}

/// Text lines of a text card's preview.
func textLines(_ p: Pen, _ card: CGRect, from y: CGFloat, widths: [CGFloat], alpha: CGFloat = 0.2) {
    let pad = card.height * 0.075
    let thick = card.height * 0.058
    let step = card.height * 0.125
    for (i, w) in widths.enumerated() {
        let line = CGRect(x: card.minX + pad, y: y + CGFloat(i) * step, width: (card.width - pad * 2) * w, height: thick)
        p.fill(capsule(line), color(black, alpha))
    }
}

/// A plain card: an opaque white fill with a hairline edge and a soft contact shadow.
func cardFill(_ p: Pen, _ path: CGPath, fill: CGFloat = 1, shadow: (y: CGFloat, blur: CGFloat, alpha: CGFloat) = (4, 12, 0.10)) {
    p.layer {
        p.shadow(y: shadow.y, blur: shadow.blur, color(0x0B1A33, shadow.alpha))
        p.fill(path, color(white, fill))
    }
    if !p.tiny { p.stroke(path, 1.5, color(black, 0.07)) }
}

/// A small landscape picture: dawn sky, sun, two hills.
func picture(_ p: Pen, _ r: CGRect, radius: CGFloat) {
    let path = rounded(r, radius)
    p.layer {
        p.clip(path)
        p.fill(path, gradient([(0, color(0x7FB6FF)), (0.62, color(0xFFD7A8)), (1, color(0xFFB98A))]),
               CGPoint(x: 0, y: r.minY), CGPoint(x: 0, y: r.maxY))
        if p.tiny {
            // Too small for hills: sky over a dark band.
            p.fill(CGPath(rect: CGRect(x: r.minX, y: r.minY + r.height * 0.55, width: r.width, height: r.height * 0.45),
                          transform: nil), color(0x2F5597))
            return
        }
        let sun = r.height * 0.15
        p.fill(CGPath(ellipseIn: box(r.minX + r.width * 0.68, r.minY + r.height * 0.44, sun * 2, sun * 2), transform: nil),
               color(0xFFF6E0))
        let back = CGMutablePath()
        back.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.72))
        back.addQuadCurve(to: CGPoint(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.70),
                          control: CGPoint(x: r.minX + r.width * 0.28, y: r.minY + r.height * 0.36))
        back.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.66),
                          control: CGPoint(x: r.minX + r.width * 0.84, y: r.minY + r.height * 0.52))
        back.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        back.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        back.closeSubpath()
        p.fill(back, color(0x6C8DCC))
        let front = CGMutablePath()
        front.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.86))
        front.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.80),
                           control: CGPoint(x: r.minX + r.width * 0.58, y: r.minY + r.height * 0.56))
        front.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        front.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        front.closeSubpath()
        p.fill(front, color(0x2F5597))
    }
}

/// The selection ring: accent, a little outside the card, concentric with it.
func ring(_ p: Pen, _ card: CGRect, radius: CGFloat, width: CGFloat, gap: CGFloat) {
    let out = gap + width / 2
    p.stroke(rounded(card.insetBy(dx: -out, dy: -out), radius + out), width, color(accent))
}

// MARK: - 1 Shelf

func shelf(_ p: Pen, _ body: CGRect) {
    // The desk: a bright blue wallpaper, light falling from the top, colour for the glass to frost.
    p.fill(CGPath(rect: body, transform: nil),
           gradient([(0, color(0xA9CBF7)), (0.55, color(0x5E92E6)), (1, color(0x3A63C4))]),
           CGPoint(x: 0, y: body.minY), CGPoint(x: 0, y: body.maxY))
    p.glow(CGPoint(x: 300, y: 180), 460, color(0xE6F1FF, 0.75))
    p.glow(CGPoint(x: 820, y: 760), 420, color(0x9F86F5, 0.55))
    p.glow(CGPoint(x: 220, y: 860), 380, color(0x38B6F0, 0.5))

    // The panel, inset from the sides and bottom like the real one, concentric at the bottom.
    let inset: CGFloat = p.tiny ? 56 : 36
    let panelTop: CGFloat = p.tiny ? 440 : 452
    let panel = CGRect(x: body.minX + inset, y: panelTop, width: body.width - inset * 2,
                       height: body.maxY - inset - panelTop)
    let shape = rounded(panel, top: p.tiny ? 96 : 76, bottom: 185 - inset)
    p.layer {
        p.shadow(y: 16, blur: 48, color(0x0E1C44, 0.30))
        p.fill(shape, color(0xDCE8F8, 0.6))
    }
    p.fill(shape, gradient([(0, color(white, 0.58)), (1, color(0xEEF4FF, 0.42))]),
           CGPoint(x: 0, y: panel.minY), CGPoint(x: 0, y: panel.maxY))
    if !p.tiny {
        p.rim(shape, 3, glassRim, top: panel.minY, bottom: panel.maxY)
        p.stroke(shape, 1.5, color(black, 0.08))
        // The resize pill.
        p.fill(capsule(box(512, panel.minY + 26, 76, 12)), color(black, 0.26))
    }

    // The card row: the picked card in the middle, its neighbours running under the glass edges.
    let w: CGFloat = p.tiny ? 448 : 432, h: CGFloat = p.tiny ? 304 : 288, gap: CGFloat = p.tiny ? 64 : 32
    let r: CGFloat = p.tiny ? 48 : 38
    let top = panel.minY + (p.tiny ? 64 : 62)
    let middle = CGRect(x: 512 - w / 2, y: top, width: w, height: h)
    p.layer {
        p.clip(shape)
        for side in [-1, 1] as [CGFloat] {
            let card = middle.offsetBy(dx: side * (w + gap), dy: 0)
            cardFill(p, rounded(card, r), fill: 0.82)
            if !p.tiny {
                let y = header(p, card, tile: side < 0 ? (0x5AC8FA, 0x007AFF) : (0xFFD60A, 0xFF9F0A))
                textLines(p, card, from: y + 6, widths: [0.92, 0.8, 0.88, 0.5])
            }
        }
    }
    cardFill(p, rounded(middle, r))
    if p.tiny {
        picture(p, middle.insetBy(dx: 40, dy: 40), radius: 16)
    } else {
        let y = header(p, middle, tile: (0x34C759, 0x248A3D))
        picture(p, CGRect(x: middle.minX + 12, y: y, width: w - 24, height: middle.maxY - 12 - y), radius: r - 12)
    }
    ring(p, middle, radius: r, width: p.tiny ? max(28, p.pixel) : 12, gap: p.tiny ? 0 : 8)
}

// MARK: - 2 Lift

func lift(_ p: Pen, _ body: CGRect) {
    // Calm light ground, cooler and a touch deeper at the bottom.
    p.fill(CGPath(rect: body, transform: nil), gradient([(0, color(0xF2F6FB)), (1, color(0xBCCBE0))]),
           CGPoint(x: 0, y: body.minY), CGPoint(x: 0, y: body.maxY))
    p.glow(CGPoint(x: 512, y: 900), 480, color(0x7FB0FF, 0.35))

    let w: CGFloat = p.tiny ? 600 : 500, h: CGFloat = p.tiny ? 400 : 332, r: CGFloat = p.tiny ? 64 : 50

    // The stack left behind: the next clip on top, older ones stepping back below it.
    if p.tiny {
        let card = box(512, 676, w * 0.92, h * 0.92)
        cardFill(p, rounded(card, r), shadow: (3, 10, 0.12))
        picture(p, card.insetBy(dx: 36, dy: 36), radius: r - 36)
    } else {
        let stack: [(cy: CGFloat, scale: CGFloat, fill: UInt32)] =
            [(728, 0.84, 0xD5DEEB), (690, 0.9, 0xE8EDF5), (650, 0.96, 0xFFFFFF)]
        for layer in stack {
            let card = box(512, layer.cy, w * layer.scale, h * layer.scale)
            let path = rounded(card, r * layer.scale)
            p.layer {
                p.shadow(y: 4, blur: 14, color(0x0B1A33, 0.16))
                p.fill(path, color(layer.fill))
            }
            p.stroke(path, 1.5, color(black, 0.06))
            if layer.fill == 0xFFFFFF {
                picture(p, card.insetBy(dx: 12, dy: 12), radius: r * layer.scale - 12)
            }
        }
    }

    // The picked card, lifting off with the drag tilt, the accent ring around it.
    let card = p.tiny ? box(520, 410, w, h) : box(530, 386, w, h)
    p.turned(p.tiny ? -10 : -9, around: CGPoint(x: card.midX, y: card.midY)) {
        let path = rounded(card, r)
        p.layer {
            p.shadow(y: 30, blur: 60, color(0x0B1A33, 0.28))
            p.fill(path, color(white))
        }
        if p.tiny {
            for (i, wf) in [0.78, 0.5].enumerated() {
                p.fill(capsule(CGRect(x: card.minX + 80, y: card.minY + 104 + CGFloat(i) * 120,
                                      width: (w - 160) * wf, height: 64)), color(black, 0.34))
            }
        } else {
            p.fill(path, gradient([(0, color(white)), (1, color(0xF4F7FB))]),
                   CGPoint(x: 0, y: card.minY), CGPoint(x: 0, y: card.maxY))
            p.stroke(path, 1.5, color(black, 0.06))
            let y = header(p, card, tile: (0x5AC8FA, 0x007AFF))
            textLines(p, card, from: y + 4, widths: [0.94, 0.84, 0.9, 0.52], alpha: 0.24)
        }
        ring(p, card, radius: r, width: p.tiny ? max(40, p.pixel) : 14, gap: p.tiny ? 0 : 10)
    }
}

// MARK: - 3 Clip

/// A clip as one bent wire, in its own units (about 160 by 380), the single loop at the top.
/// `front` is the tongue that lies in front of the card; `back` is the loop behind it.
func clipWire() -> (front: CGPath, back: CGPath) {
    let front = CGMutablePath()
    front.move(to: CGPoint(x: -22, y: 150))
    front.addLine(to: CGPoint(x: -22, y: 310))
    front.addArc(center: CGPoint(x: 0, y: 310), radius: 22, startAngle: .pi, endAngle: 0, clockwise: true)
    front.addLine(to: CGPoint(x: 22, y: 44))
    front.addArc(center: CGPoint(x: -22, y: 44), radius: 44, startAngle: 0, endAngle: .pi, clockwise: true)
    let back = CGMutablePath()
    back.move(to: CGPoint(x: -66, y: 44))
    back.addLine(to: CGPoint(x: -66, y: 310))
    back.addArc(center: CGPoint(x: 0, y: 310), radius: 66, startAngle: .pi, endAngle: 0, clockwise: true)
    back.addLine(to: CGPoint(x: 66, y: 180))
    return (front, back)
}

func clip(_ p: Pen, _ body: CGRect) {
    // Night desk: the prototype's dark wallpaper, lit from above.
    p.fill(CGPath(rect: body, transform: nil), gradient([(0, color(0x27305E)), (1, color(0x0D1024))]),
           CGPoint(x: 0, y: body.minY), CGPoint(x: 0, y: body.maxY))
    p.glow(CGPoint(x: 512, y: 300), 520, color(0x3D6BFF, 0.30))

    let card = p.tiny ? box(512, 566, 660, 440) : box(512, 572, 612, 408)
    let r: CGFloat = p.tiny ? 64 : 56
    let path = rounded(card, r)

    let scale: CGFloat = p.tiny ? 1.5 : 1.3
    let wire: CGFloat = p.tiny ? max(30, p.pixel * 0.9) : 24
    let (front, back) = clipWire()
    var place = CGAffineTransform(translationX: card.minX + card.width * 0.76, y: card.minY - 104 * scale)
        .rotated(by: -6 * .pi / 180).scaledBy(x: scale, y: scale)
    let frontPath = front.copy(using: &place)!, backPath = back.copy(using: &place)!

    func drawWire(_ wirePath: CGPath) {
        p.layer {
            p.ctx.addPath(wirePath)
            p.ctx.setLineWidth(wire)
            p.ctx.setLineCap(.round)
            p.ctx.setLineJoin(.round)
            p.ctx.replacePathWithStrokedPath()
            let outline = p.ctx.path!
            p.layer {
                p.shadow(y: 6, blur: 10, color(0x000814, 0.35))
                p.fill(outline, color(accent))
            }
            p.fill(outline, gradient([(0, color(0x8CCBFF)), (0.45, color(accent)), (1, color(0x0060DF))]),
                   CGPoint(x: 0, y: card.minY - 140), CGPoint(x: 0, y: card.minY + 360))
        }
        if !p.tiny {
            // A thin highlight along the wire.
            p.layer {
                p.ctx.translateBy(x: -4, y: -3)
                p.stroke(wirePath, 4, color(white, 0.45))
            }
        }
    }

    drawWire(backPath)
    cardFill(p, path, shadow: (18, 40, 0.45))
    if p.tiny {
        for (i, wf) in [0.6, 0.4].enumerated() {
            p.fill(capsule(CGRect(x: card.minX + 72, y: card.minY + 160 + CGFloat(i) * 120,
                                  width: (card.width - 144) * wf, height: 64)), color(black, 0.3))
        }
    } else {
        let y = header(p, card, tile: (0xFF6482, 0xFF2D55))
        textLines(p, card, from: y + 4, widths: [0.6, 0.52, 0.58, 0.34], alpha: 0.22)
    }
    drawWire(frontPath)
}

// MARK: - The icon

func icon(_ design: Int, pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: k, y: -k)
    ctx.interpolationQuality = .high
    let p = Pen(ctx: ctx, k: k, tiny: pixels <= 32)

    // The macOS icon grid: an 824 pt body with continuous corners, 100 pt from each edge.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = rounded(body, 185)

    if pixels >= 64 {
        p.layer {
            p.shadow(y: 10, blur: 20, color(black, 0.28))
            p.fill(shape, color(0x808080))
        }
    }
    p.layer {
        p.clip(shape)
        switch design {
        case 1: shelf(p, body)
        case 3: clip(p, body)
        default: lift(p, body)
        }
    }
    if pixels >= 64 {
        p.rim(shape, 4, gradient([(0, color(white, 0.5)), (0.5, color(white, 0.06)), (1, color(white, 0.12))]),
              top: body.minY, bottom: body.maxY)
    }
    return ctx.makeImage()!
}

// MARK: - Files

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "png", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't write \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "png", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't write \(url.path)"])
    }
}

func writeIcns(_ design: Int, to output: URL) throws {
    let iconset = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipnpaste-\(ProcessInfo.processInfo.processIdentifier).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }
    for base in [16, 32, 128, 256, 512] {
        try writePNG(icon(design, pixels: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try writePNG(icon(design, pixels: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw NSError(domain: "iconutil", code: Int(iconutil.terminationStatus))
    }
}

/// A sheet with a y-up canvas, for laying out previews.
func sheet(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

func label(_ ctx: CGContext, _ text: String, at point: CGPoint, size: CGFloat, _ c: CGColor) {
    let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
    let string = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): c,
    ])
    ctx.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(string), ctx)
}

/// Draws `image` at its own pixel size, or blown up with hard pixel edges.
func place(_ ctx: CGContext, _ image: CGImage, x: CGFloat, top: CGFloat, height: Int, size: CGFloat? = nil) {
    let side = size ?? CGFloat(image.width)
    ctx.saveGState()
    ctx.interpolationQuality = size == nil ? .high : .none
    ctx.draw(image, in: CGRect(x: x, y: CGFloat(height) - top - side, width: side, height: side))
    ctx.restoreGState()
}

func writeCompare(to folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let light = color(0xF0F0F3), dark = color(0x1C1C1F)

    // One sheet per design: the 1024 px icon, then 128, 64, 32 and 16 px, and 32 and 16 px blown up.
    for design in 1...3 {
        let h = 1024
        let image = sheet(1024 + 420, h) { ctx in
            ctx.setFillColor(light)
            ctx.fill(CGRect(x: 0, y: 0, width: 1024 + 420, height: h))
            place(ctx, icon(design, pixels: 1024), x: 0, top: 0, height: h)
            let x: CGFloat = 1024 + 24
            place(ctx, icon(design, pixels: 128), x: x, top: 64, height: h)
            place(ctx, icon(design, pixels: 64), x: x + 152, top: 128, height: h)
            place(ctx, icon(design, pixels: 32), x: x + 240, top: 160, height: h)
            place(ctx, icon(design, pixels: 16), x: x + 296, top: 176, height: h)
            place(ctx, icon(design, pixels: 32), x: x, top: 260, height: h, size: 256)
            place(ctx, icon(design, pixels: 16), x: x, top: 556, height: h, size: 256)
            label(ctx, "\(design)  \(names[design]!)", at: CGPoint(x: x, y: 80), size: 30, color(black, 0.8))
            label(ctx, "32 px and 16 px, each pixel enlarged", at: CGPoint(x: x, y: 40), size: 18, color(black, 0.5))
        }
        try writePNG(image, to: folder.appendingPathComponent("option-\(design).png"))
    }

    // All three side by side at 512, 128 and 32 px, on light and on dark.
    let column = 600, band = 780
    let image = sheet(column * 3, band * 2) { ctx in
        for (row, (ground, ink)) in [(light, color(black, 0.8)), (dark, color(white, 0.85))].enumerated() {
            let top = row * band
            ctx.setFillColor(ground)
            ctx.fill(CGRect(x: 0, y: band * 2 - top - band, width: column * 3, height: band))
            for design in 1...3 {
                let x = CGFloat((design - 1) * column + 44)
                label(ctx, "\(design)  \(names[design]!)\(design == defaultDesign ? "  (default)" : "")",
                      at: CGPoint(x: x + 16, y: CGFloat(band * 2 - top - 52)), size: 26, ink)
                place(ctx, icon(design, pixels: 512), x: x, top: CGFloat(top + 72), height: band * 2)
                place(ctx, icon(design, pixels: 128), x: x + 64, top: CGFloat(top + 600), height: band * 2)
                place(ctx, icon(design, pixels: 32), x: x + 240, top: CGFloat(top + 648), height: band * 2)
            }
        }
    }
    try writePNG(image, to: folder.appendingPathComponent("compare.png"))
    print("Wrote option-1.png ... option-3.png and compare.png to \(folder.path)")
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if let flag = arguments.firstIndex(of: "--compare") {
        guard flag + 1 < arguments.count else { throw NSError(domain: "usage", code: 2) }
        try writeCompare(to: URL(fileURLWithPath: arguments[flag + 1]))
        return
    }
    let design = arguments.first.flatMap(Int.init) ?? defaultDesign
    guard names[design] != nil else {
        FileHandle.standardError.write("Design must be 1, 2 or 3.\n".data(using: .utf8)!)
        exit(2)
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let output = root.appendingPathComponent("Resources/AppIcon.icns")
    try writeIcns(design, to: output)
    print("Wrote \(output.path) from design \(design) (\(names[design]!))")
}

try main()

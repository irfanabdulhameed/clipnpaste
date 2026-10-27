import AppKit
import SwiftUI

/// Colours from the approved prototype. Each one is dynamic, so light and dark follow the system.
enum Palette {
    /// Black at `light` opacity in light mode, white at `dark` opacity in dark mode.
    static func ink(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
        pair(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: light), NSColor(srgbRed: 1, green: 1, blue: 1, alpha: dark))
    }

    static func pair(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func gray(_ v: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: v / 255, green: v / 255, blue: v / 255, alpha: alpha)
    }

    static let label = ink(0.85, 0.88)
    static let label2 = ink(0.56, 0.60)
    static let label3 = ink(0.45, 0.46)
    static let label2Contrast = ink(0.74, 0.80)
    static let label3Contrast = ink(0.64, 0.70)

    static let cardFill = pair(gray(255, 0.72), gray(30, 0.64))
    static let cardFillOpaque = pair(gray(255), gray(30))
    static let cardHair = ink(0.07, 0.09)
    static let cardBorderContrast = ink(0.38, 0.42)
    static let loadFill = ink(0.06, 0.06)
    static let hover = ink(0.06, 0.06)
    static let hoverContrast = ink(0.10, 0.10)
    static let press = ink(0.10, 0.10)
    static let button = ink(0.08, 0.08)
    static let buttonHover = ink(0.16, 0.16)
    static let buttonPress = ink(0.24, 0.24)
    static let pill = ink(0.35, 0.35)
    static let pillContrast = ink(0.60, 0.60)
    static let accentRing = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.5 : 0.45)
    }
    static let amber = NSColor(srgbRed: 0xF5 / 255, green: 0xA6 / 255, blue: 0x23 / 255, alpha: 1)
    static let checkA = gray(128, 0.12)
    static let checkB = gray(128, 0.06)
    /// The panel's 0.5 pt outline, used by the classic and opaque surfaces (the glass draws its own rim).
    static let edge = pair(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10), NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
}

/// The colour roles a view needs, resolved for the current accessibility settings.
struct Theme {
    var increaseContrast = false
    var reduceTransparency = false
    var reduceMotion = false

    var label: Color { Color(nsColor: Palette.label) }
    var label2: Color { Color(nsColor: increaseContrast ? Palette.label2Contrast : Palette.label2) }
    var label3: Color { Color(nsColor: increaseContrast ? Palette.label3Contrast : Palette.label3) }
    var accent: Color { Color(nsColor: .controlAccentColor) }
    var accentRing: Color { Color(nsColor: Palette.accentRing) }
    var cardFill: Color { Color(nsColor: reduceTransparency ? Palette.cardFillOpaque : Palette.cardFill) }
    var cardHair: Color { increaseContrast ? .clear : Color(nsColor: Palette.cardHair) }
    var cardBorder: Color? { increaseContrast ? Color(nsColor: Palette.cardBorderContrast) : nil }
    var loadFill: Color { Color(nsColor: Palette.loadFill) }
    var hover: Color { Color(nsColor: increaseContrast ? Palette.hoverContrast : Palette.hover) }
    var press: Color { Color(nsColor: Palette.press) }
    var button: Color { Color(nsColor: Palette.button) }
    var buttonHover: Color { Color(nsColor: Palette.buttonHover) }
    var buttonPress: Color { Color(nsColor: Palette.buttonPress) }
    var pill: Color { Color(nsColor: increaseContrast ? Palette.pillContrast : Palette.pill) }
    var amber: Color { Color(nsColor: Palette.amber) }
    var checkA: Color { Color(nsColor: Palette.checkA) }
    var checkB: Color { Color(nsColor: Palette.checkB) }
    var ringWidth: CGFloat { increaseContrast ? 3.5 : 2.5 }
}

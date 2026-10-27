import AppKit
import Testing
@testable import ClipnpasteCore

@Suite struct MenuBarGlyphTests {
    let designs = MenuBarGlyph.names.keys.sorted()

    @Test func everyDesignFillsItsBitmapsExactly() {
        for d in designs {
            for scale in [1, 2] {
                let rows = MenuBarGlyph.rows(d, scale: scale)
                #expect(rows.count == MenuBarGlyph.height * scale, "design \(d) at \(scale)×")
                for row in rows {
                    #expect(row.count == MenuBarGlyph.width * scale, "design \(d) at \(scale)×")
                    #expect(row.allSatisfy { MenuBarGlyph.alpha($0) != nil }, "design \(d) at \(scale)×")
                }
            }
        }
    }

    @Test func onePixelVersionsAreSolidOrClear() {
        // The external displays are 1×: no soft pixels there at all.
        for d in designs {
            #expect(MenuBarGlyph.rows(d, scale: 1).joined().allSatisfy { $0 == "." || $0 == "#" }, "design \(d)")
        }
    }

    @Test func twoPixelVersionsCoverTheSameShape() {
        // The 2× drawing spans exactly twice the 1× one (counting pixels at least half covered).
        func bounds(_ rows: [String]) -> [Int] {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for (y, row) in rows.enumerated() {
                for (x, c) in row.enumerated() where (MenuBarGlyph.alpha(c) ?? 0) >= 0.5 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return [minX, minY, maxX, maxY]
        }
        for d in designs {
            let one = bounds(MenuBarGlyph.rows(d, scale: 1)), two = bounds(MenuBarGlyph.rows(d, scale: 2))
            #expect(two == [one[0] * 2, one[1] * 2, one[2] * 2 + 1, one[3] * 2 + 1], "design \(d)")
        }
    }

    @Test func imageIsATemplateWithOneAndTwoTimesPixels() {
        #expect(MenuBarGlyph.names[MenuBarGlyph.chosen] != nil)
        // Even sizes, so the status bar centres the image on whole pixels.
        #expect(MenuBarGlyph.width % 2 == 0 && MenuBarGlyph.height % 2 == 0)
        let image = MenuBarGlyph.image()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: MenuBarGlyph.width, height: MenuBarGlyph.height))
        #expect(image.representations.map(\.pixelsWide).sorted() == [MenuBarGlyph.width, MenuBarGlyph.width * 2])
        #expect(image.representations.map(\.pixelsHigh).sorted() == [MenuBarGlyph.height, MenuBarGlyph.height * 2])
    }
}

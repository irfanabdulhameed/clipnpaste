import Testing
import Foundation
import CoreGraphics
@testable import ClipnpasteCore

@Suite struct ThumbnailerTests {
    /// The thumbnail must cover the largest card box (292 × 168 pt) at 2×.
    static let box = (width: 584, height: 336)

    @Test func sizeMaths() {
        // 16:9 screenshot: the height binds.
        #expect(Thumbnailer.maxPixelSize(width: 3840, height: 2160) == 598)
        // Phone screenshot: the width binds, about 1,040 px tall at 9:16.
        #expect(Thumbnailer.maxPixelSize(width: 1080, height: 1920) == 1039)
        // Never upscaled.
        #expect(Thumbnailer.maxPixelSize(width: 100, height: 60) == 100)
        #expect(Thumbnailer.maxPixelSize(width: 600, height: 300) == 600)
        // A very long capture is capped.
        #expect(Thumbnailer.maxPixelSize(width: 1000, height: 40_000) == Thumbnailer.maxSide)
    }

    @Test(arguments: [(3840, 2160), (1170, 2532), (2000, 2000)])
    func largeImagesCoverTheBox(width: Int, height: Int) throws {
        let thumb = try #require(Thumbnailer.thumbnailPNG(from: TestImages.png(width: width, height: height)))
        let image = try #require(TestImages.decode(thumb))
        #expect(image.width >= Self.box.width && image.height >= Self.box.height)
        #expect(max(image.width, image.height) == Thumbnailer.maxPixelSize(width: width, height: height))
        // Only just covers: one side fits the box.
        #expect(image.width <= Self.box.width + 1 || image.height <= Self.box.height + 1)
    }

    @Test func smallImagesKeepTheirSize() throws {
        let thumb = try #require(Thumbnailer.thumbnailPNG(from: TestImages.png(width: 120, height: 80)))
        let image = try #require(TestImages.decode(thumb))
        #expect(image.width == 120 && image.height == 80)
    }

    @Test func transparencyIsKept() throws {
        let png = TestImages.png(width: 1600, height: 1000, transparentLeft: true)
        let thumb = try #require(Thumbnailer.thumbnailPNG(from: png))
        #expect(thumb.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let image = try #require(TestImages.decode(thumb))
        #expect(![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo))
        #expect(TestImages.alpha(of: image, x: 2, y: image.height / 2) == 0)
        #expect(TestImages.alpha(of: image, x: image.width - 3, y: image.height / 2) == 255)
    }
}

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum Thumbnailer {
    /// The largest card thumbnail box in the plan (2560×1440 display), in points.
    public static let boxWidth = 292
    public static let boxHeight = 168
    public static let scale = 2
    /// Caps very long images (a scrolling capture) so a thumbnail never gets huge.
    public static let maxSide = 2048

    /// The long side, in pixels, at which the image covers the box at 2× (aspect-fill).
    /// Never larger than the image itself.
    public static func maxPixelSize(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let bw = Double(boxWidth * scale), bh = Double(boxHeight * scale)
        let s = min(max(bw / Double(width), bh / Double(height)), 1)
        let long = (Double(max(width, height)) * s).rounded(.up)
        return min(Int(long), max(width, height), maxSide)
    }

    /// A downsampled PNG of the image in `data`. PNG keeps any transparency.
    public static func thumbnailPNG(from data: Data) -> Data? {
        guard let source = ImageCodec.source(data), let size = ImageCodec.pixelSize(source) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize(width: size.width, height: size.height),
        ]
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        return ImageCodec.png(image)
    }
}

enum ImageCodec {
    static func source(_ data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard CGImageSourceGetCount(source) > index,
              let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { return nil }
        return (w, h)
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        source(data).flatMap(pixelSize)
    }

    static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// PNG bytes for image data of any type ImageIO reads. PNG input is kept as is;
    /// anything else is decoded with its orientation applied and re-encoded.
    static func normalizedPNG(_ data: Data, isPNG: Bool) -> Data? {
        guard let source = source(data), let size = pixelSize(source) else { return nil }
        if isPNG { return data }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, index, nil)
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        }
        return image.flatMap(png)
    }
}

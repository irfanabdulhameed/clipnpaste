import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ClipnpasteCore

/// A pasteboard the tests fill by hand.
@MainActor
final class FakePasteboard: PasteboardAccess {
    var changeCount = 0
    private var data: [String: Data] = [:]
    private var strings: [String: String] = [:]
    private var urls: [URL] = []

    var types: Set<String> {
        var all = Set(data.keys).union(strings.keys)
        if !urls.isEmpty { all.insert(PasteboardTypes.fileURL) }
        return all
    }

    func data(forType type: String) -> Data? { data[type] ?? strings[type].map { Data($0.utf8) } }
    func string(forType type: String) -> String? { strings[type] }
    func fileURLs() -> [URL] { urls }

    /// Replaces the contents, like a copy in another app.
    func copy(strings: [String: String] = [:], data: [String: Data] = [:], urls: [URL] = []) {
        changeCount += 1
        self.strings = strings
        self.data = data
        self.urls = urls
    }

    func copy(text: String) { copy(strings: [PasteboardTypes.plainText: text]) }
}

/// A temporary folder; call `remove()` in a `defer`.
struct TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "clipnpaste-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

enum TestImages {
    /// An image filled with one colour; optionally the left half fully transparent.
    static func cgImage(width: Int, height: Int, gray: CGFloat = 0.5, transparentLeft: Bool = false) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: gray, green: 1 - gray, blue: 0.3, alpha: 1))
        let x = transparentLeft ? width / 2 : 0
        ctx.fill(CGRect(x: x, y: 0, width: width - x, height: height))
        return ctx.makeImage()!
    }

    static func encode(_ image: CGImage, as type: UTType) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func png(width: Int, height: Int, gray: CGFloat = 0.5, transparentLeft: Bool = false) -> Data {
        encode(cgImage(width: width, height: height, gray: gray, transparentLeft: transparentLeft), as: .png)
    }

    static func tiff(width: Int, height: Int, gray: CGFloat = 0.5) -> Data {
        encode(cgImage(width: width, height: height, gray: gray), as: .tiff)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The alpha byte of pixel (x, y), counting y from the top.
    static func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels[(y * image.width + x) * 4 + 3]
    }
}

extension Clip {
    static func text(_ s: String, at date: Date = Date()) -> Clip {
        Clip(kind: .text, plainText: s, createdAt: date, contentHash: ContentHash.of(s))
    }
}

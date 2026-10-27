import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClipnpasteCore

/// A decoded thumbnail, or why there is none.
enum Thumbnail: @unchecked Sendable {
    case image(CGImage, hasAlpha: Bool)
    /// The clip's image file is gone, so the card is disabled.
    case missing
    case unreadable
}

/// Decodes thumbnails off the main thread and keeps the recent ones in memory.
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private final class Entry {
        let value: Thumbnail
        init(_ value: Thumbnail) { self.value = value }
    }

    private let cache: NSCache<NSUUID, Entry> = {
        let c = NSCache<NSUUID, Entry>()
        c.totalCostLimit = 30 * 1024 * 1024
        return c
    }()

    func cached(_ id: UUID) -> Thumbnail? { cache.object(forKey: id as NSUUID)?.value }

    func load(_ clip: Clip, maxPixel: Int) async -> Thumbnail {
        if let hit = cached(clip.id) { return hit }
        let thumb = clip.thumbnailURL, image = clip.imageURL
        let result = await Task.detached(priority: .userInitiated) {
            Self.decode(thumbnail: thumb, image: image, maxPixel: maxPixel)
        }.value
        var cost = 1
        if case .image(let img, _) = result { cost = img.bytesPerRow * img.height }
        cache.setObject(Entry(result), forKey: clip.id as NSUUID, cost: cost)
        return result
    }

    nonisolated private static func decode(thumbnail: URL?, image: URL?, maxPixel: Int) -> Thumbnail {
        let fm = FileManager.default
        guard let image, fm.fileExists(atPath: image.path) else { return .missing }
        let url = thumbnail.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } ?? image
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let hasAlpha = props?[kCGImagePropertyHasAlpha] as? Bool ?? false
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return .unreadable }
        return .image(cg, hasAlpha: hasAlpha)
    }

    /// Longest side in pixels that still covers `box` at 2× after aspect-fill, never upscaled.
    nonisolated static func maxPixel(for clip: Clip, box: CGSize) -> Int {
        guard let w = clip.pixelWidth, let h = clip.pixelHeight, w > 0, h > 0 else { return 1100 }
        let scale = max(box.width / CGFloat(w), box.height / CGFloat(h))
        let side = CGFloat(max(w, h)) * scale * 2
        return Int(min(side.rounded(.up), CGFloat(max(w, h))))
    }
}

/// Source-app icons, looked up once per bundle id.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static let generic = NSWorkspace.shared.icon(for: .applicationBundle)

    static func icon(for bundleID: String?) -> NSImage {
        guard let bundleID else { return generic }
        if let hit = cache[bundleID] { return hit }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? generic
        cache[bundleID] = icon
        return icon
    }
}

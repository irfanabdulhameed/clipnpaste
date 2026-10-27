import Foundation
import CryptoKit

/// SHA-256 hex, the clip de-duplication key.
public enum ContentHash {
    public static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func of(_ text: String) -> String { of(Data(text.utf8)) }
}

/// Where image clips keep their files: the PNG in `images/`, its thumbnail in `thumbs/`,
/// both named by the clip's content hash.
public struct ClipFiles: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var images: URL { root.appending(path: "images", directoryHint: .isDirectory) }
    public var thumbs: URL { root.appending(path: "thumbs", directoryHint: .isDirectory) }

    public func imageURL(hash: String) -> URL {
        images.appending(path: "\(hash).png", directoryHint: .notDirectory)
    }

    public func thumbnailURL(hash: String) -> URL {
        thumbs.appending(path: "\(hash).png", directoryHint: .notDirectory)
    }

    public func createDirectories() throws {
        for dir in [images, thumbs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// True when `url` sits inside this folder, so it is ours to delete.
    public func owns(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(root.path + "/")
    }

    /// Deletes a file only if it is ours.
    func delete(_ url: URL?) {
        guard let url, owns(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// How a URL is kept in the database: relative to the root when inside it, so the
    /// folder can move; absolute otherwise.
    func storedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return owns(url) ? String(path.dropFirst(root.path.count + 1)) : path
    }

    func url(forStoredPath path: String) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: false)
            : root.appending(path: path, directoryHint: .notDirectory)
    }

    static func fileSize(_ url: URL?) -> Int64 {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }
}

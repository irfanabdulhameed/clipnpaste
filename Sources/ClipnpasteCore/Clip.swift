import Foundation

public enum ClipKind: String, Sendable, Codable, Equatable {
    case text
    case image
}

public struct Clip: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var kind: ClipKind
    public var plainText: String?
    public var rtfData: Data?
    public var htmlData: Data?
    public var imageURL: URL?
    public var thumbnailURL: URL?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var characterCount: Int
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var createdAt: Date
    /// Manual panel position; smaller is nearer the front. Fractional, so a move changes one clip.
    public var sortKey: Double
    /// SHA-256 hex of the plain text, or of the PNG bytes for images.
    public var contentHash: String

    public init(
        id: UUID = UUID(),
        kind: ClipKind,
        plainText: String? = nil,
        rtfData: Data? = nil,
        htmlData: Data? = nil,
        imageURL: URL? = nil,
        thumbnailURL: URL? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        characterCount: Int? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        createdAt: Date = Date(),
        sortKey: Double = 0,
        contentHash: String
    ) {
        self.id = id
        self.kind = kind
        self.plainText = plainText
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.characterCount = characterCount ?? plainText?.count ?? 0
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
        self.sortKey = sortKey
        self.contentHash = contentHash
    }
}

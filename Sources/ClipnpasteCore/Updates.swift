import Foundation

// What the updater decides, kept apart from the network and the windows so it can be tested:
// reading GitHub's latest release, comparing versions, choosing the disk image, reading what
// GitHub answered, the notes excerpt, and when to check.

/// A version like 1.0.3: major, minor and patch, compared as numbers, so 1.0.10 is newer than 1.0.9.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// The part after a hyphen, as in 1.1.0-beta.1. Empty for an ordinary release.
    public var prerelease: String

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0, prerelease: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Reads "1.0.3", "v1.0.3", "1.2" (1.2.0) or "1.1.0-beta.1". Build metadata after a plus is
    /// ignored. nil for anything that isn't a version.
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var prerelease = ""
        if let hyphen = rest.firstIndex(of: "-") {
            prerelease = String(rest[rest.index(after: hyphen)...])
            rest = rest[..<hyphen]
            if prerelease.isEmpty { return nil }
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2], prerelease: prerelease)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// A pre-release comes before its release: 1.1.0-beta < 1.1.0.
    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        return a.prerelease.compare(b.prerelease, options: .numeric) == .orderedAscending
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-\(prerelease)")
    }
}

/// A file attached to a release.
public struct ReleaseAsset: Equatable, Sendable {
    public var name: String
    public var url: URL
    public var size: Int64

    public init(name: String, url: URL, size: Int64) {
        self.name = name
        self.url = url
        self.size = size
    }
}

/// GitHub's latest release.
public struct Release: Equatable, Sendable {
    public var tag: String
    public var version: SemanticVersion
    public var name: String
    /// The release notes, in Markdown.
    public var notes: String
    public var isDraft: Bool
    public var isPrerelease: Bool
    /// The release's page on GitHub.
    public var page: URL?
    /// Clipnpaste.dmg, when it is attached.
    public var dmg: ReleaseAsset?

    public init(tag: String, version: SemanticVersion, name: String = "", notes: String = "",
                isDraft: Bool = false, isPrerelease: Bool = false, page: URL? = nil, dmg: ReleaseAsset? = nil) {
        self.tag = tag
        self.version = version
        self.name = name
        self.notes = notes
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.page = page
        self.dmg = dmg
    }

    /// An ordinary release, the only kind offered: not a draft and not a pre-release.
    public var isStable: Bool { !isDraft && !isPrerelease && !version.isPrerelease }
}

public enum ReleaseFeed {
    /// The disk image every release carries.
    public static let assetName = "Clipnpaste.dmg"
    public static let latestURL = URL(string: "https://api.github.com/repos/irfanabdulhameed/clipnpaste/releases/latest")!

    public enum ParseError: Error, Equatable {
        /// The answer isn't a release.
        case notARelease
        /// The release's tag isn't a version.
        case badTag(String)
    }

    /// Reads the JSON GitHub answers `GET /repos/{owner}/{repo}/releases/latest` with.
    public static func parseLatest(_ data: Data) throws -> Release {
        let entry: Entry
        do {
            entry = try JSONDecoder().decode(Entry.self, from: data)
        } catch {
            throw ParseError.notARelease
        }
        guard let version = SemanticVersion(entry.tag_name) else { throw ParseError.badTag(entry.tag_name) }
        let assets = (entry.assets ?? []).compactMap(\.value).compactMap { asset in
            URL(string: asset.browser_download_url).map { ReleaseAsset(name: asset.name, url: $0, size: asset.size ?? 0) }
        }
        return Release(tag: entry.tag_name, version: version, name: entry.name ?? "", notes: entry.body ?? "",
                       isDraft: entry.draft ?? false, isPrerelease: entry.prerelease ?? false,
                       page: entry.html_url.flatMap(URL.init(string:)), dmg: selectAsset(assets))
    }

    /// Clipnpaste.dmg: the exact name first, then the same name in other letter case. Any other
    /// file (a zip, another disk image, the source code) is never chosen.
    public static func selectAsset(_ assets: [ReleaseAsset]) -> ReleaseAsset? {
        let https = assets.filter { $0.url.scheme == "https" || $0.url.isFileURL }
        return https.first { $0.name == assetName }
            ?? https.first { $0.name.compare(assetName, options: .caseInsensitive) == .orderedSame }
    }

    private struct Entry: Decodable {
        var tag_name: String
        var name: String?
        var body: String?
        var draft: Bool?
        var prerelease: Bool?
        var html_url: String?
        var assets: [Lossy<Asset>]?
    }

    private struct Asset: Decodable {
        var name: String
        var size: Int64?
        var browser_download_url: String
    }

    /// Decodes a value, or nil when it doesn't fit, so one odd asset doesn't spoil the release.
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}

/// What a check found out.
public enum UpdateCheckOutcome: Equatable, Sendable {
    case upToDate
    case available(Release)
    /// GitHub says there is nothing to see (404, 401, 403): the repository isn't public yet.
    case notPublic
    case failed(UpdateCheckFailure)
}

public enum UpdateCheckFailure: Equatable, Sendable {
    /// GitHub limits how often a Mac may ask without an account.
    case rateLimited
    case status(Int)
    case unreadable

    public var message: String {
        switch self {
        case .rateLimited: "GitHub is limiting how often Clipnpaste can ask. Try again in an hour."
        case .status(let code): "GitHub answered with error \(code)."
        case .unreadable: "GitHub's answer couldn't be read."
        }
    }
}

public enum UpdateCheck {
    /// Turns GitHub's answer into what the About section shows. `headers` are the response's,
    /// with lowercase names.
    public static func outcome(status: Int, headers: [String: String] = [:], data: Data,
                               current: SemanticVersion) -> UpdateCheckOutcome {
        switch status {
        case 200:
            guard let release = try? ReleaseFeed.parseLatest(data) else { return .failed(.unreadable) }
            return offer(release, current: current).map(UpdateCheckOutcome.available) ?? .upToDate
        case 403 where headers["x-ratelimit-remaining"] == "0", 429:
            return .failed(.rateLimited)
        case 401, 403, 404:
            return .notPublic
        default:
            return .failed(.status(status))
        }
    }

    /// The release, when it is an ordinary one newer than `current` with Clipnpaste.dmg
    /// attached. A release still being made (no disk image yet) isn't offered.
    public static func offer(_ release: Release, current: SemanticVersion) -> Release? {
        guard release.isStable, release.version > current, release.dmg != nil else { return nil }
        return release
    }
}

public enum ReleaseNotes {
    /// The first few lines of the notes as plain text: headings, rules, code blocks, HTML comments
    /// and GitHub's "Full Changelog" line left out; bullets, emphasis, code marks and links removed.
    public static func excerpt(_ markdown: String, maxLines: Int = 4) -> [String] {
        var out: [String] = []
        var inComment = false
        var inFence = false
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            var line = String(raw)
            if inComment {
                guard let end = line.range(of: "-->") else { continue }
                line = String(line[end.upperBound...])
                inComment = false
            }
            while let start = line.range(of: "<!--") {
                if let end = line.range(of: "-->", range: start.upperBound..<line.endIndex) {
                    line.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    line = String(line[..<start.lowerBound])
                    inComment = true
                }
            }
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") || text.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence || text.isEmpty || text.lowercased().hasPrefix("**full changelog**") { continue }
            if text.allSatisfy({ "-*_ ".contains($0) }) { continue }
            if text.first == "#" { continue }
            for mark in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where text.hasPrefix(mark) {
                text = String(text.dropFirst(mark.count))
                break
            }
            text = plain(text).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            out.append(text)
            if out.count == maxLines { break }
        }
        return out
    }

    /// Markdown links become their words, and **, __, ` marks go.
    private static func plain(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "["), let mid = s.range(of: "](", range: open.upperBound..<s.endIndex),
              let close = s.range(of: ")", range: mid.upperBound..<s.endIndex) {
            let words = s[open.upperBound..<mid.lowerBound]
            s.replaceSubrange(open.lowerBound..<close.upperBound, with: words)
        }
        for mark in ["**", "__", "`"] { s = s.replacingOccurrences(of: mark, with: "") }
        return s
    }
}

/// The updater's words, where they depend on numbers.
public enum UpdateText {
    /// "2.4 of 6.1 MB", in decimal megabytes like Finder. Just "2.4 MB" when the size isn't known.
    public static func progress(received: Int64, total: Int64?, locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(1)).grouping(.automatic)
        func megabytes(_ bytes: Int64) -> String { (Double(max(bytes, 0)) / 1_000_000).formatted(style) }
        guard let total, total > 0 else { return "\(megabytes(received)) MB" }
        return "\(megabytes(min(received, total))) of \(megabytes(total)) MB"
    }
}

/// When Clipnpaste checks by itself.
public enum UpdatePolicy {
    /// The first check, this long after launch.
    public static let launchDelay: TimeInterval = 10
    /// At most once a day.
    public static let interval: TimeInterval = 24 * 3600

    /// True when the last automatic or manual check was a day ago or more (or never), or the
    /// clock went backwards.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let gap = now.timeIntervalSince(lastCheck)
        return gap >= interval || gap < 0
    }
}

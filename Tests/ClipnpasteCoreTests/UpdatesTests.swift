import Testing
import Foundation
@testable import ClipnpasteCore

@Suite struct SemanticVersionTests {
    @Test func readsVersions() {
        #expect(SemanticVersion("0.1.1") == SemanticVersion(0, 1, 1))
        #expect(SemanticVersion("v1.2.3") == SemanticVersion(1, 2, 3))
        #expect(SemanticVersion("1.2") == SemanticVersion(1, 2, 0))
        #expect(SemanticVersion("2") == SemanticVersion(2, 0, 0))
        #expect(SemanticVersion("1.0.0+42") == SemanticVersion(1, 0, 0))
        #expect(SemanticVersion("1.1.0-beta.2")?.prerelease == "beta.2")
    }

    @Test(arguments: ["", "v", "1.", "1..2", "1.2.3.4", "one", "1.2.x", "1.0.0-", " -1.0"])
    func rejectsNonVersions(_ text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test func comparesAsNumbers() {
        let v = { SemanticVersion($0)! }
        #expect(v("0.1.10") > v("0.1.9"))
        #expect(v("0.2.0") > v("0.1.99"))
        #expect(v("1.0.0") > v("0.99.99"))
        #expect(v("0.1.1") == v("v0.1.1"))
        #expect(!(v("0.1.1") < v("0.1.1")))
        #expect(v("1.1.0-beta") < v("1.1.0"))
        #expect(v("1.1.0-beta.2") < v("1.1.0-beta.10"))
        #expect(v("1.1.0-rc.1") > v("1.0.9"))
    }
}

@Suite struct ReleaseFeedTests {
    static func json(tag: String = "v0.1.2", draft: Bool = false, prerelease: Bool = false,
                     assets: String = Self.dmgAsset) -> Data {
        Data("""
        {
          "url": "https://api.github.com/repos/irfanabdulhameed/clipnpaste/releases/1",
          "html_url": "https://github.com/irfanabdulhameed/clipnpaste/releases/tag/\(tag)",
          "tag_name": "\(tag)",
          "name": "Clipnpaste \(tag)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "published_at": "2026-10-28T09:00:00Z",
          "body": "## What's new\\n- **Faster** history\\n- Fixed a crash",
          "assets": [\(assets)]
        }
        """.utf8)
    }

    static let dmgAsset = """
    {"name": "Clipnpaste.dmg", "size": 6100000, "content_type": "application/x-apple-diskimage",
     "browser_download_url": "https://github.com/irfanabdulhameed/clipnpaste/releases/download/v0.1.2/Clipnpaste.dmg"}
    """

    @Test func parsesTheLatestRelease() throws {
        let release = try ReleaseFeed.parseLatest(Self.json())
        #expect(release.tag == "v0.1.2")
        #expect(release.version == SemanticVersion(0, 1, 2))
        #expect(release.name == "Clipnpaste v0.1.2")
        #expect(release.notes.contains("Faster"))
        #expect(release.isStable)
        #expect(release.page?.absoluteString == "https://github.com/irfanabdulhameed/clipnpaste/releases/tag/v0.1.2")
        #expect(release.dmg?.name == "Clipnpaste.dmg")
        #expect(release.dmg?.size == 6_100_000)
        #expect(release.dmg?.url.host == "github.com")
    }

    @Test func toleratesMissingOptionalFieldsAndOddAssets() throws {
        let data = Data(#"{"tag_name": "0.2.0", "assets": [{"name": 5}, {"name": "Clipnpaste.dmg", "browser_download_url": "https://x.test/Clipnpaste.dmg"}]}"#.utf8)
        let release = try ReleaseFeed.parseLatest(data)
        #expect(release.version == SemanticVersion(0, 2, 0))
        #expect(release.notes == "")
        #expect(release.dmg?.size == 0)
    }

    @Test func rejectsWhatIsntARelease() {
        #expect(throws: ReleaseFeed.ParseError.notARelease) { try ReleaseFeed.parseLatest(Data("[]".utf8)) }
        #expect(throws: ReleaseFeed.ParseError.notARelease) { try ReleaseFeed.parseLatest(Data(#"{"message": "Not Found"}"#.utf8)) }
        #expect(throws: ReleaseFeed.ParseError.notARelease) { try ReleaseFeed.parseLatest(Data("not json".utf8)) }
        #expect(throws: ReleaseFeed.ParseError.badTag("nightly")) { try ReleaseFeed.parseLatest(Self.json(tag: "nightly")) }
    }

    @Test func choosesOnlyTheClipnpasteDiskImage() {
        func asset(_ name: String, _ url: String = "https://github.com/a/b") -> ReleaseAsset {
            ReleaseAsset(name: name, url: URL(string: url + "/" + name)!, size: 1)
        }
        #expect(ReleaseFeed.selectAsset([asset("Clipnpaste.zip"), asset("Clipnpaste.dmg"), asset("Other.dmg")])?.name == "Clipnpaste.dmg")
        #expect(ReleaseFeed.selectAsset([asset("clipnpaste.DMG")])?.name == "clipnpaste.DMG")
        #expect(ReleaseFeed.selectAsset([asset("clipnpaste.DMG"), asset("Clipnpaste.dmg")])?.name == "Clipnpaste.dmg")
        #expect(ReleaseFeed.selectAsset([asset("Clipnpaste.zip"), asset("Clipnpaste-0.1.2.dmg"), asset("Source.tar.gz")]) == nil)
        #expect(ReleaseFeed.selectAsset([]) == nil)
        // Never over plain HTTP.
        #expect(ReleaseFeed.selectAsset([asset("Clipnpaste.dmg", "http://github.com/a/b")]) == nil)
    }
}

@Suite struct UpdateCheckTests {
    let current = SemanticVersion(0, 1, 1)

    @Test func newerReleaseIsOffered() {
        let outcome = UpdateCheck.outcome(status: 200, data: ReleaseFeedTests.json(tag: "v0.1.2"), current: current)
        guard case .available(let release) = outcome else {
            Issue.record("expected an offer, got \(outcome)")
            return
        }
        #expect(release.version == SemanticVersion(0, 1, 2))
    }

    @Test func sameOrOlderIsUpToDate() {
        #expect(UpdateCheck.outcome(status: 200, data: ReleaseFeedTests.json(tag: "v0.1.1"), current: current) == .upToDate)
        #expect(UpdateCheck.outcome(status: 200, data: ReleaseFeedTests.json(tag: "v0.1.0"), current: current) == .upToDate)
    }

    @Test func draftsPrereleasesAndReleasesWithoutTheDiskImageAreNotOffered() {
        #expect(UpdateCheck.outcome(status: 200, data: ReleaseFeedTests.json(draft: true), current: current) == .upToDate)
        #expect(UpdateCheck.outcome(status: 200, data: ReleaseFeedTests.json(prerelease: true), current: current) == .upToDate)
        #expect(UpdateCheck.outcome(status: 200, data: ReleaseFeedTests.json(tag: "v0.2.0-beta.1"), current: current) == .upToDate)
        #expect(UpdateCheck.outcome(status: 200, data: ReleaseFeedTests.json(assets: ""), current: current) == .upToDate)
    }

    /// The repository is private for now: GitHub answers 404 (or 401, 403) without an account.
    @Test(arguments: [404, 401, 403])
    func hiddenRepositoryIsNotPublicNotAnError(_ status: Int) {
        let body = Data(#"{"message": "Not Found", "documentation_url": "https://docs.github.com/rest"}"#.utf8)
        #expect(UpdateCheck.outcome(status: status, data: body, current: current) == .notPublic)
    }

    @Test func rateLimitIsAnErrorNotPrivate() {
        let body = Data(#"{"message": "API rate limit exceeded"}"#.utf8)
        #expect(UpdateCheck.outcome(status: 403, headers: ["x-ratelimit-remaining": "0"], data: body, current: current)
                == .failed(.rateLimited))
        #expect(UpdateCheck.outcome(status: 429, data: body, current: current) == .failed(.rateLimited))
        #expect(UpdateCheck.outcome(status: 403, headers: ["x-ratelimit-remaining": "41"], data: body, current: current)
                == .notPublic)
    }

    @Test func otherAnswersAreErrors() {
        #expect(UpdateCheck.outcome(status: 500, data: Data(), current: current) == .failed(.status(500)))
        #expect(UpdateCheck.outcome(status: 200, data: Data("<html>".utf8), current: current) == .failed(.unreadable))
    }
}

@Suite struct ReleaseNotesTests {
    @Test func excerptIsPlainText() {
        let notes = """
        <!-- written by hand -->
        ## What's new
        - **Check for updates** in [Settings](https://example.com)
        * Uses `hdiutil` quietly

        ---
        1. Numbered stays as is
        - Fourth line
        - Fifth line is cut

        **Full Changelog**: https://github.com/a/b/compare/v0.1.1...v0.1.2
        """
        #expect(ReleaseNotes.excerpt(notes) == [
            "Check for updates in Settings", "Uses hdiutil quietly", "1. Numbered stays as is", "Fourth line",
        ])
        #expect(ReleaseNotes.excerpt(notes, maxLines: 2).count == 2)
        #expect(ReleaseNotes.excerpt("") == [])
        #expect(ReleaseNotes.excerpt("```\ncode\n```\n- After the fence") == ["After the fence"])
    }
}

@Suite struct UpdatePolicyTests {
    @Test func atMostOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdatePolicy.isDue(lastCheck: nil, now: now))
        #expect(!UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(!UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-86_399), now: now))
        #expect(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        // A clock set back doesn't stop checks for good.
        #expect(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }

    @Test func progressText() {
        let en = Locale(identifier: "en_US")
        #expect(UpdateText.progress(received: 2_400_000, total: 6_100_000, locale: en) == "2.4 of 6.1 MB")
        #expect(UpdateText.progress(received: 9_000_000, total: 6_100_000, locale: en) == "6.1 of 6.1 MB")
        #expect(UpdateText.progress(received: 2_400_000, total: nil, locale: en) == "2.4 MB")
    }
}

@MainActor @Suite struct UpdatePreferencesTests {
    @Test func automaticChecksAreOnByDefaultAndPersist() {
        let name = "com.irfanabdulhameed.clipnpaste.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let p = Preferences(defaults: d)
        #expect(p.checkForUpdates)
        #expect(p.lastUpdateCheck == nil)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        p.checkForUpdates = false
        p.lastUpdateCheck = when
        let again = Preferences(defaults: d)
        #expect(!again.checkForUpdates)
        #expect(again.lastUpdateCheck == when)
    }
}

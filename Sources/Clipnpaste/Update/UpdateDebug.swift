import AppKit
import ClipnpasteCore

/// Launch arguments for checking the updater without a real release.
///
///   --update-state NAME           Settings › About shows one state (idle, checking, uptodate,
///                                 available, downloading, installing, error, private); with
///                                 --show-settings about, for screenshots. Nothing is fetched.
///   --fake-update DMG [--fake-version V]
///                                 Every check finds version V (default: this version's patch + 1)
///                                 with DMG as its disk image. Refuses to install over a copy in
///                                 /Applications or ~/Applications.
///   --update-check [--accept] [--relaunch-probe FILE]
///                                 Checks, prints what it found and quits. --accept installs over
///                                 this copy and relaunches it; with --relaunch-probe the new copy
///                                 only writes its version to FILE and quits.
///   --write-version FILE          Writes CFBundleShortVersionString to FILE and quits at once.
@MainActor
enum UpdateDebug {
    private static let args = ProcessInfo.processInfo.arguments

    private static func value(after flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    static let stateName = value(after: "--update-state")
    static let fakeDMG = value(after: "--fake-update").map { URL(fileURLWithPath: $0) }
    static let isCommand = args.contains("--update-check")
    /// Any updater flag keeps the run away from the real history, settings and menu bar.
    static var isOn: Bool { stateName != nil || fakeDMG != nil || isCommand }

    /// `--write-version FILE`, handled before the app starts.
    nonisolated static func writeVersionIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--write-version"), args.indices.contains(i + 1) else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "none"
        try? Data((version + "\n").utf8).write(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }

    /// The made-up release for `--fake-update`.
    nonisolated static func fakeRelease(current: SemanticVersion) -> Release? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--fake-update"), args.indices.contains(i + 1) else { return nil }
        let dmg = URL(fileURLWithPath: args[i + 1])
        let named = args.firstIndex(of: "--fake-version").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let version = named.flatMap(SemanticVersion.init) ?? SemanticVersion(current.major, current.minor, current.patch + 1)
        let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Release(tag: "v\(version)", version: version, name: "Clipnpaste \(version)",
                       notes: "- A test release made from a local disk image.",
                       dmg: ReleaseAsset(name: ReleaseFeed.assetName, url: dmg, size: size))
    }

    /// Fake updates never replace an installed copy.
    static func refusal(for app: URL) -> String? {
        guard fakeDMG != nil else { return nil }
        let path = app.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/") {
            return "A test update never replaces an installed copy. Run it on a copy in a temporary folder."
        }
        return nil
    }

    /// The state `--update-state` asks for, with sample content.
    static func shownState(current: SemanticVersion) -> Updater.State? {
        guard let name = stateName else { return nil }
        let next = SemanticVersion(current.major, current.minor, current.patch + 1)
        let release = Release(
            tag: "v\(next)", version: next, name: "Clipnpaste \(next)",
            notes: """
            ## What's new
            - **Check for updates** in Settings › About and the menu-bar menu
            - Images copied from Preview keep their transparency
            - Fixed: the panel sometimes opened on the wrong display after waking
            - Faster history search with 10,000 clips
            """,
            dmg: ReleaseAsset(name: ReleaseFeed.assetName, url: URL(string: "https://example.com/Clipnpaste.dmg")!, size: 6_100_000))
        switch name {
        case "idle": return .idle
        case "checking": return .checking
        case "uptodate": return .upToDate
        case "available": return .available(release)
        case "downloading": return .downloading(release, received: 2_400_000, total: 6_100_000)
        case "installing": return .installing(release)
        case "error": return .failed(UpdateFailure.offline.message, retry: .check)
        case "private": return .notPublic
        default: return nil
        }
    }

    // MARK: --update-check

    /// Runs the headless check; true when it took over this launch.
    static func runIfAsked() -> Bool {
        guard isCommand else { return false }
        let accept = args.contains("--accept")
        let updater = Updater(prefs: Preferences.app)
        updater.relaunchProbe = value(after: "--relaunch-probe").map { URL(fileURLWithPath: $0) }
        print("app: \(Bundle.main.bundleURL.path)")
        print("running: \(updater.current?.description ?? "no version")")
        if let mine = Signature(Bundle.main.bundleURL) {
            print("signed: \(mine.isSigned ? "certificate" : "ad hoc"), team \(mine.team ?? "none")")
        }
        keep = updater
        updater.check()
        Task { @MainActor in
            var last: Updater.State?
            var accepted = false
            while true {
                let state = updater.state
                if state != last {
                    last = state
                    report(state)
                    switch state {
                    case .available where accept && !accepted:
                        accepted = true
                        print("pressing Install and relaunch")
                        updater.install()
                    case .available, .upToDate, .notPublic:
                        exit(0)
                    case .failed:
                        exit(1)
                    default:
                        break
                    }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return true
    }

    private static var keep: Updater?

    private static func report(_ state: Updater.State) {
        switch state {
        case .idle: print("state: idle")
        case .checking: print("state: checking")
        case .upToDate: print("state: up to date")
        case .available(let r): print("state: version \(r.version) available, notes: \(ReleaseNotes.excerpt(r.notes))")
        case .downloading(_, let received, let total): print("state: downloading \(UpdateText.progress(received: received, total: total))")
        case .installing: print("state: installing")
        case .notPublic: print("state: not public")
        case .failed(let message, _): print("state: failed: \(message)")
        }
        fflush(stdout)
    }
}

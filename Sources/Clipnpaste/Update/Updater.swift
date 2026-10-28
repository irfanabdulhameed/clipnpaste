import AppKit
import ClipnpasteCore

/// Asks GitHub for the latest release. One request with nothing about the user in it: no token,
/// no cookies, no cache, only a User-Agent naming the app and its version.
enum UpdateClient {
    static var currentVersion: SemanticVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init)
    }

    static var userAgent: String { "Clipnpaste/\(currentVersion?.description ?? "0")" }

    static func check(current: SemanticVersion) async throws -> UpdateCheckOutcome {
        if let fake = UpdateDebug.fakeRelease(current: current) { return .available(fake) }
        var request = URLRequest(url: ReleaseFeed.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateFailure.check(.unreadable) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return UpdateCheck.outcome(status: http.statusCode, headers: headers, data: data, current: current)
    }
}

/// The updater behind Settings › About and the menu-bar menu.
///
/// By hand: Check for updates shows every step. By itself (Check for updates automatically, on by
/// default): about 10 s after launch, then at most once a day, silently; a newer version only
/// adds "Update to X…" to the menu-bar menu. Installing never happens in the middle of a paste or
/// a drag, and touches only the app bundle.
@MainActor @Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, received: Int64, total: Int64?)
        case installing(Release)
        /// GitHub hides the releases (404, 401, 403): the repository isn't public yet.
        case notPublic
        case failed(String, retry: Retry)
    }

    enum Retry: Equatable {
        case check
        case install(Release)
    }

    private(set) var state: State = .idle
    /// A newer version found by any check and not installed yet: the menu offers it.
    private(set) var pending: Release? {
        didSet { if pending != oldValue { onPendingChange?(pending) } }
    }
    @ObservationIgnored var onPendingChange: ((Release?) -> Void)?
    /// False while the panel is open, a drag is under way or a paste was just sent.
    @ObservationIgnored var isIdle: () -> Bool = { true }

    let current: SemanticVersion?
    let prefs: Preferences
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored let installer = UpdateInstaller()
    /// Debug runs: the relaunched copy only writes its version here.
    @ObservationIgnored var relaunchProbe: URL?

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    init(prefs: Preferences, current: SemanticVersion? = UpdateClient.currentVersion) {
        self.prefs = prefs
        self.current = current
        if let shown = UpdateDebug.shownState(current: current ?? SemanticVersion(0, 1, 1)) {
            state = shown
            if case .available(let release) = shown { pending = release }
        }
    }

    // MARK: Automatic checks

    /// The first automatic check 10 s after launch, then a look every hour whether a day has passed.
    func start() {
        guard timer == nil, current != nil else { return }
        let first = Timer(timeInterval: UpdatePolicy.launchDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        RunLoop.main.add(first, forMode: .common)
        let hourly = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        RunLoop.main.add(hourly, forMode: .common)
        timer = hourly
    }

    private func checkIfDue() {
        guard prefs.checkForUpdates, UpdatePolicy.isDue(lastCheck: prefs.lastUpdateCheck, now: Date()) else { return }
        check(silently: true)
    }

    // MARK: Actions

    /// Asks GitHub. A silent check changes nothing on screen unless it finds a newer version.
    func check(silently: Bool = false) {
        guard !isBusy, let current else { return }
        if !silently { state = .checking }
        prefs.lastUpdateCheck = Date()
        task = Task { [weak self] in
            let outcome: Result<UpdateCheckOutcome, UpdateFailure>
            do {
                outcome = .success(try await UpdateClient.check(current: current))
            } catch {
                outcome = .failure(UpdateFailure(error))
            }
            guard let self, !Task.isCancelled else { return }
            self.finishCheck(outcome, silently: silently)
        }
    }

    private func finishCheck(_ outcome: Result<UpdateCheckOutcome, UpdateFailure>, silently: Bool) {
        switch outcome {
        case .success(.available(let release)):
            pending = release
            // A silent find shows in About only when About isn't busy with something else.
            if !silently || state == .idle || state == .upToDate || state == .notPublic { state = .available(release) }
        case .success(.upToDate):
            pending = nil
            if !silently { state = .upToDate }
        case .success(.notPublic):
            if !silently { state = .notPublic }
        case .success(.failed(let failure)):
            appLog("update check: \(failure.message)")
            if !silently { state = .failed(failure.message, retry: .check) }
        case .failure(let failure):
            appLog("update check: \(failure.message)")
            if !silently { state = .failed(failure.message, retry: .check) }
        }
    }

    /// Install and relaunch: download, verify, replace, relaunch.
    func install() {
        guard !isBusy, let current else { return }
        let release: Release
        switch state {
        case .available(let r), .failed(_, .install(let r)): release = r
        default:
            guard let p = pending else { return }
            release = p
        }
        if let refusal = UpdateDebug.refusal(for: Bundle.main.bundleURL) {
            state = .failed(refusal, retry: .install(release))
            return
        }
        state = .downloading(release, received: 0, total: release.dmg.map(\.size).flatMap { $0 > 0 ? $0 : nil })
        installer.isIdle = { [weak self] in self?.isIdle() ?? true }
        installer.onProgress = { [weak self] received, total in
            guard let self, case .downloading = self.state else { return }
            self.state = .downloading(release, received: received, total: total)
        }
        installer.onInstalling = { [weak self] in self?.state = .installing(release) }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.installer.install(release, current: current)
                self.pending = nil
                try await self.installer.relaunch(Bundle.main.bundleURL, probe: self.relaunchProbe)
            } catch is CancellationError {
                self.state = .available(release)
            } catch {
                let failure = UpdateFailure(error)
                appLog("update install: \(failure.message)")
                self.state = .failed(failure.message, retry: .install(release))
            }
        }
    }

    /// Stops a download in progress; the offer stays.
    func cancel() {
        guard case .downloading(let release, _, _) = state else { return }
        task?.cancel()
        state = .available(release)
    }

    func retry() {
        guard case .failed(_, let retry) = state else { return }
        switch retry {
        case .check: check()
        case .install: install()
        }
    }
}

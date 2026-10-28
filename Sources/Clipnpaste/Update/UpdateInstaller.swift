import AppKit
import Security
import ClipnpasteCore

/// Why an update didn't work, in plain words for the About section.
enum UpdateFailure: Error, Equatable {
    case offline
    case timedOut
    case unreachable
    case check(UpdateCheckFailure)
    case downloadStatus(Int)
    case incomplete
    case damaged
    case notClipnpaste
    case notNewer
    case unsigned
    case differentSigner
    case cantReplace(String)
    case other(String)

    init(_ error: Error) {
        if let failure = error as? UpdateFailure {
            self = failure
        } else if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: self = .offline
            case .timedOut: self = .timedOut
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed: self = .unreachable
            default: self = .other(error.localizedDescription)
            }
        } else {
            self = .other(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .offline: "Your Mac seems to be offline."
        case .timedOut: "GitHub didn't answer in time."
        case .unreachable: "Clipnpaste couldn't reach GitHub."
        case .check(let failure): failure.message
        case .downloadStatus(let code): "GitHub didn't send the update (error \(code))."
        case .incomplete: "The download stopped before it was complete."
        case .damaged: "The download is damaged."
        case .notClipnpaste: "The download isn't Clipnpaste."
        case .notNewer: "The download isn't newer than this version."
        case .unsigned: "This copy of Clipnpaste isn't signed, so it can't check an update. Download the new version from GitHub instead."
        case .differentSigner: "The download isn't signed by the same developer as this copy, so it wasn't installed."
        case .cantReplace(let reason): "Clipnpaste couldn't replace itself. \(reason)"
        case .other(let reason): reason
        }
    }
}

/// Downloads Clipnpaste.dmg, checks the app inside and puts it in place of the running one.
///
/// Every file it makes lives in one temporary folder that is deleted on every path, and the disk
/// image is always detached. Clips (Application Support) and settings (preferences) are never
/// touched: only the app bundle is replaced.
@MainActor
final class UpdateInstaller {
    var onProgress: (Int64, Int64?) -> Void = { _, _ in }
    var onInstalling: () -> Void = {}
    /// Asked before the swap and before quitting: false while a paste or a drag is under way.
    var isIdle: () -> Bool = { true }

    /// Downloads, verifies and replaces `app`. Returns when the new copy is in place.
    func install(_ release: Release, current: SemanticVersion, app: URL = Bundle.main.bundleURL) async throws {
        guard let asset = release.dmg else { throw UpdateFailure.notClipnpaste }
        if let reason = Self.whyNotReplaceable(app) { throw UpdateFailure.cantReplace(reason) }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Clipnpaste Update \(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var mount: URL?
        defer {
            // A disk image that wouldn't detach keeps its folder, so nothing on it is touched.
            if mount == nil { try? fm.removeItem(at: work) }
        }

        let dmg = work.appendingPathComponent(ReleaseFeed.assetName)
        try await UpdateDownload.run(asset.url, to: dmg, expected: asset.size) { [weak self] received, total in
            self?.onProgress(received, total)
        }
        try Task.checkCancellation()
        onInstalling()

        let mounted = try await Self.attach(dmg, under: work)
        mount = mounted
        do {
            let found = try Self.findApp(in: mounted)
            try Self.verify(found, running: app, current: current)
            let staged = try Self.stage(found, beside: app)
            defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
            if await Self.detach(mounted) { mount = nil }
            await waitUntilIdle()
            try Self.swap(app, with: staged)
        } catch {
            if mount != nil, await Self.detach(mounted) { mount = nil }
            throw error
        }
    }

    /// Never in the middle of a paste or a drag: waits for the panel to be closed and still.
    func waitUntilIdle() async {
        while !isIdle() { try? await Task.sleep(for: .milliseconds(250)) }
    }

    /// Opens `app` once this process has quit, then quits. `probe` (debug runs) makes the new copy
    /// only write its version to that file instead of starting.
    func relaunch(_ app: URL, probe: URL? = nil) async throws {
        await waitUntilIdle()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits (up to 10 s) for this process to quit, so macOS starts the new copy instead of
        // bringing the old one forward.
        let wait = "i=0; while kill -0 \(getpid()) 2>/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done; sleep 0.5; "
        if let probe {
            process.arguments = ["-c", wait + #""$0/Contents/MacOS/Clipnpaste" --write-version "$1""#, app.path, probe.path]
        } else {
            process.arguments = ["-c", wait + #"open "$0""#, app.path]
        }
        try process.run()
        NSApp.terminate(nil)
    }

    // MARK: Steps

    /// Why Clipnpaste can't replace itself where it is, or nil when it can.
    static func whyNotReplaceable(_ app: URL) -> String? {
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent()
        let readOnly = (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if app.pathExtension != "app" || app.path.contains("/AppTranslocation/") || readOnly {
            return "It's running from a disk image or a temporary place. Move it to Applications and try again."
        }
        if !fm.isWritableFile(atPath: folder.path) || !fm.isWritableFile(atPath: app.path) {
            return "It can't write to the folder it's in. Download the new version from GitHub instead."
        }
        return nil
    }

    /// Mounts the disk image read-only, out of sight (no Finder window, no Desktop icon).
    private static func attach(_ dmg: URL, under folder: URL) async throws -> URL {
        let result = try? await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                         "-mountrandom", folder.path, "-plist", dmg.path])
        guard let result, result.status == 0 else {
            appLog("update: couldn't mount the disk image: \(result?.stderr ?? "hdiutil didn't run")")
            throw UpdateFailure.damaged
        }
        let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let path = entities.lazy.compactMap({ $0["mount-point"] as? String }).first else { throw UpdateFailure.damaged }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Detaches the disk image; true when it is gone.
    @discardableResult
    private static func detach(_ mount: URL) async -> Bool {
        if (try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]))?.status == 0 { return true }
        if (try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]))?.status == 0 { return true }
        appLog("update: couldn't detach \(mount.path)")
        return false
    }

    private static func findApp(in mount: URL) throws -> URL {
        let named = mount.appendingPathComponent("Clipnpaste.app")
        if FileManager.default.fileExists(atPath: named.appendingPathComponent("Contents/Info.plist").path) { return named }
        let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1 else { throw UpdateFailure.notClipnpaste }
        return apps[0]
    }

    /// The same bundle identifier, a newer version, an intact signature, and the same signer as
    /// the running copy: the new app must satisfy the running app's designated requirement, and
    /// carry the same team (or, for a personal certificate without a team, the same certificate).
    static func verify(_ new: URL, running: URL, current: SemanticVersion) throws {
        let info = NSDictionary(contentsOf: new.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let runningInfo = NSDictionary(contentsOf: running.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard let identifier = info?["CFBundleIdentifier"] as? String,
              identifier == runningInfo?["CFBundleIdentifier"] as? String else { throw UpdateFailure.notClipnpaste }
        guard let text = info?["CFBundleShortVersionString"] as? String, let version = SemanticVersion(text),
              version > current else { throw UpdateFailure.notNewer }

        guard let mine = Signature(running), mine.isSigned, let requirement = mine.requirement else {
            throw UpdateFailure.unsigned
        }
        guard let theirs = Signature(new) else { throw UpdateFailure.damaged }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(theirs.code, flags, nil) == errSecSuccess else {
            appLog("update: the download's signature doesn't check out")
            throw UpdateFailure.damaged
        }
        let sameSigner = SecStaticCodeCheckValidity(theirs.code, flags, requirement) == errSecSuccess
        let sameIdentity = mine.team != nil ? mine.team == theirs.team : (mine.leaf != nil && mine.leaf == theirs.leaf)
        guard sameSigner, sameIdentity else {
            appLog("update: signer differs (team \(mine.team ?? "none") vs \(theirs.team ?? "none"))")
            throw UpdateFailure.differentSigner
        }
    }

    /// Copies the new app next to the running one (same disk), so the swap is a rename.
    private static func stage(_ found: URL, beside app: URL) throws -> URL {
        let fm = FileManager.default
        do {
            let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: app.deletingLastPathComponent(), create: true)
            let staged = folder.appendingPathComponent(app.lastPathComponent)
            try fm.copyItem(at: found, to: staged)
            return staged
        } catch {
            throw UpdateFailure.cantReplace(error.localizedDescription)
        }
    }

    /// Replaces the app bundle in place, in one step.
    private static func swap(_ app: URL, with staged: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)
        } catch {
            throw UpdateFailure.cantReplace(error.localizedDescription)
        }
    }

    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    /// Runs a tool off the main thread and collects what it printed.
    static func run(_ path: String, _ arguments: [String]) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errors = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: data,
                                                      stderr: String(decoding: errors, as: UTF8.self)))
            }
        }
    }
}

/// A bundle's code signature: its designated requirement, team and leaf certificate.
struct Signature {
    let code: SecStaticCode
    let requirement: SecRequirement?
    let team: String?
    let leaf: Data?
    /// Signed with a certificate (not ad hoc).
    var isSigned: Bool { leaf != nil }

    init?(_ bundle: URL) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        self.code = code
        var requirement: SecRequirement?
        self.requirement = SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess ? requirement : nil
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        let dict = SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess ? info as? [String: Any] : nil
        team = dict?[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = dict?[kSecCodeInfoCertificates as String] as? [SecCertificate]
        leaf = certificates?.first.map { SecCertificateCopyData($0) as Data }
    }
}

/// One download with progress, cancelled with its task.
enum UpdateDownload {
    @MainActor
    static func run(_ url: URL, to destination: URL, expected: Int64,
                    progress: @escaping @MainActor @Sendable (Int64, Int64?) -> Void) async throws {
        let total = expected > 0 ? expected : nil
        if url.isFileURL {
            // A local disk image (--fake-update), for checks.
            do { try FileManager.default.copyItem(at: url, to: destination) } catch { throw UpdateFailure.incomplete }
        } else {
            let delegate = DownloadDelegate(destination: destination) { received, reported in
                Task { @MainActor in progress(received, total ?? reported) }
            }
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue(UpdateClient.userAgent, forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    delegate.continuation = continuation
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let total, size != total { throw UpdateFailure.incomplete }
        progress(size, total ?? size)
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64?) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastReport = Date.distantPast

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 1.0 / 15 else { return }
        lastReport = now
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = UpdateFailure.downloadStatus(http.statusCode)
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = UpdateFailure.other(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = continuation
        continuation = nil
        if let error = error as? URLError, error.code == .cancelled {
            result?.resume(throwing: CancellationError())
        } else if let error {
            result?.resume(throwing: UpdateFailure(error))
        } else if let failure {
            result?.resume(throwing: failure)
        } else {
            result?.resume()
        }
    }
}

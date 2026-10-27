import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClipnpasteCore

struct PrivacySection: View {
    let env: AppEnvironment
    @State private var confirm: Confirm?
    @State private var confirmShown = false
    @State private var clearShown = false
    @State private var clipCount = 0
    @State private var imageBytes: Int64?

    /// A tighter limit that would delete clips, waiting for a yes.
    enum Confirm {
        case clips(Int, removes: Int)
        case images(Int64)
        case age(Int, removes: Int)

        var title: String {
            switch self {
            case .clips(let n, _): "Keep up to \(n.formatted()) clips?"
            case .images(let b): "Lower image storage to \(bytes(b))?"
            case .age(let d, _): "Auto-clear clips older than \(PrivacySection.age(d))?"
            }
        }

        var message: String {
            switch self {
            case .clips(_, let r): "This removes the \(count(r, oldest: true)). It can't be undone."
            case .images(let b): "The oldest images are removed until the rest fit in \(bytes(b)). It can't be undone."
            case .age(let d, let r): "This removes \(count(r)) older than \(PrivacySection.age(d)). It can't be undone."
            }
        }

        var action: String {
            switch self {
            case .clips(_, let r), .age(_, let r): r == 1 ? "Remove 1 Clip" : "Remove \(r.formatted()) Clips"
            case .images(let b): "Lower to \(bytes(b))"
            }
        }

        private func count(_ n: Int, oldest: Bool = false) -> String {
            n == 1 ? (oldest ? "oldest clip" : "1 clip") : (oldest ? "\(n.formatted()) oldest clips" : "\(n.formatted()) clips")
        }
    }

    var body: some View {
        @Bindable var prefs = env.preferences
        Form {
            Section("History") {
                Picker(selection: clipsBinding) {
                    ForEach(Preferences.clipChoices, id: \.self) { Text("\($0.formatted()) clips").tag($0) }
                } label: {
                    Text("Keep up to")
                    Text("The oldest clips go first.")
                }

                Picker(selection: imagesBinding) {
                    ForEach(Preferences.imageChoices, id: \.self) { Text(bytes($0)).tag($0) }
                } label: {
                    Text("Image storage")
                    Text(imageCaption)
                }

                Picker(selection: ageBinding) {
                    ForEach(Preferences.autoClearChoices, id: \.self) { Text(Self.age($0)).tag($0) }
                } label: {
                    Text("Auto-clear clips older than")
                    Text("Measured from when you last copied it. Images are deleted too.")
                }
            }

            Section {
                Toggle(isOn: $prefs.captureUniversalClipboard) {
                    Text("Keep copies from iPhone and iPad")
                    Text("Universal Clipboard. When off, what you copy on your other devices isn't kept.")
                }
            }

            Section {
                if prefs.ignoredApps.isEmpty {
                    Text("Copies from every app are kept, except the password managers below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(prefs.ignoredApps, id: \.self) { id in
                    AppRow(bundleID: id) {
                        Button {
                            prefs.ignoredApps.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Keep copies from \(AppInfo.name(id)) again")
                        .accessibilityLabel("Remove \(AppInfo.name(id))")
                    }
                }
                HStack {
                    Menu("Add App") {
                        let running = AppInfo.runningApps(excluding: Set(prefs.ignoredApps))
                        if running.isEmpty {
                            Text("No other apps are open")
                        }
                        ForEach(running, id: \.self) { id in
                            Button {
                                add([id])
                            } label: {
                                Label { Text(AppInfo.name(id)) } icon: { Image(nsImage: AppInfo.icon(id, size: 16)) }
                            }
                        }
                        Divider()
                        Button("Choose from Applications…") { chooseApps() }
                    }
                    .fixedSize()
                    Spacer()
                }
                DisclosureGroup("Password managers, always ignored") {
                    ForEach(AppInfo.passwordManagers, id: \.self) { id in
                        AppRow(bundleID: id) { EmptyView() }
                    }
                }
            } header: {
                Text("Apps to ignore")
            }

            Section {
                LabeledContent {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([env.dataFolder])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: env.dataFolder.path))
                } label: {
                    Text("Data folder")
                    Text((env.dataFolder.path as NSString).abbreviatingWithTildeInPath)
                }
                LabeledContent {
                    Button("Clear History…", role: .destructive) { clearShown = true }
                        .disabled(clipCount == 0)
                } label: {
                    Text("Clear history")
                    Text(clipCount == 1 ? "1 clip kept now." : "\(clipCount.formatted()) clips kept now.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(confirm?.title ?? "", isPresented: $confirmShown, presenting: confirm) { c in
            Button(c.action, role: .destructive) { apply(c) }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
        .confirmationDialog(clipCount == 1 ? "Clear 1 clip?" : "Clear all \(clipCount.formatted()) clips?", isPresented: $clearShown) {
            Button("Clear History", role: .destructive) {
                env.retention.clearAll()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every clip and image is removed. It can't be undone.")
        }
        .task {
            refresh()
            imageBytes = await env.retention.imageBytes()
            debugConfirm()
        }
    }

    // MARK: Limits that ask first

    private var clipsBinding: Binding<Int> {
        Binding(get: { env.preferences.maxClips }, set: { n in
            let r = env.retention.removed(byMaxClips: n)
            if r > 0 { ask(.clips(n, removes: r)) } else { env.preferences.maxClips = n }
        })
    }

    private var imagesBinding: Binding<Int64> {
        Binding(get: { env.preferences.maxImageBytes }, set: { b in
            if let used = imageBytes, used > b { ask(.images(b)) } else { env.preferences.maxImageBytes = b }
        })
    }

    private var ageBinding: Binding<Int> {
        Binding(get: { env.preferences.autoClearDays }, set: { d in
            Task { @MainActor in
                let r = await env.retention.removed(byDays: d)
                if r > 0 { ask(.age(d, removes: r)) } else { env.preferences.autoClearDays = d }
            }
        })
    }

    private func ask(_ c: Confirm) {
        confirm = c
        confirmShown = true
    }

    private func apply(_ c: Confirm) {
        switch c {
        case .clips(let n, _): env.preferences.maxClips = n
        case .images(let b): env.preferences.maxImageBytes = b
        case .age(let d, _): env.preferences.autoClearDays = d
        }
        Task { @MainActor in
            // The store removes them now; give its deletes a moment before counting again.
            try? await Task.sleep(for: .milliseconds(150))
            refresh()
            imageBytes = await env.retention.imageBytes()
        }
    }

    private func refresh() { clipCount = env.store.count }

    /// `--settings-confirm clear` or `--settings-confirm age:DAYS` (debug runs): picks it as a click
    /// would, so the confirmation can be checked without touching the screen.
    private func debugConfirm() {
        guard Sandbox.isOn, let i = Sandbox.args.firstIndex(of: "--settings-confirm"), Sandbox.args.indices.contains(i + 1) else { return }
        let v = Sandbox.args[i + 1]
        if v == "clear" { clearShown = true }
        if v.hasPrefix("age:"), let d = Int(v.dropFirst(4)) { ageBinding.wrappedValue = d }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            for w in NSApp.windows where w.isVisible && (w.isSheet || w.sheetParent != nil || w is NSPanel) {
                debugLog("settings: sheet window \(w.windowNumber) \(type(of: w))")
            }
        }
    }

    private var imageCaption: String {
        let rule = "The oldest images go first."
        guard let imageBytes else { return rule }
        return "\(rule) Images use \(bytes(imageBytes)) now."
    }

    nonisolated static func age(_ days: Int) -> String {
        switch days {
        case 0: "Never"
        case 1: "1 day"
        case 365: "1 year"
        default: "\(days) days"
        }
    }

    // MARK: Apps

    private func add(_ ids: [String]) {
        let own = Bundle.main.bundleIdentifier
        let fresh = ids.filter { $0 != own && !env.preferences.ignoredApps.contains($0) }
        guard !fresh.isEmpty else { return }
        env.preferences.ignoredApps += fresh
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Ignore"
        panel.message = "Choose the apps whose copies Clipnpaste should never keep."
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            add(panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}

private func bytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

/// One app in a list: its icon and name, and a trailing control.
private struct AppRow<Trailing: View>: View {
    let bundleID: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppInfo.icon(bundleID, size: 20))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(AppInfo.name(bundleID))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            trailing()
        }
    }
}

/// Names and icons for bundle ids, from the apps installed on this Mac.
@MainActor
enum AppInfo {
    /// The built-in list, shown read-only, with names for the ones not installed.
    static let passwordManagers = CaptureRules.passwordManagers.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    private static let knownNames = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.agilebits.onepassword4": "1Password 4",
        "com.agilebits.onepassword-osx": "1Password 6",
        "com.bitwarden.desktop": "Bitwarden",
        "org.keepassxc.keepassxc": "KeePassXC",
        "com.apple.keychainaccess": "Keychain Access",
        "com.apple.passwords": "Passwords",
        "in.sinew.enpass-desktop": "Enpass",
        "com.hicknhacksoftware.macpass": "MacPass",
    ]

    static func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static func name(_ id: String) -> String {
        if let url = url(id) {
            let n = FileManager.default.displayName(atPath: url.path)
            return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
        }
        return knownNames[id] ?? id
    }

    static func icon(_ id: String, size: CGFloat) -> NSImage {
        let image = url(id).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: size, height: size)
        return copy
    }

    /// Apps open now that could be added: regular apps, not this one, not listed already.
    static func runningApps(excluding listed: Set<String>) -> [String] {
        let own = Bundle.main.bundleIdentifier
        let builtIn = CaptureRules.passwordManagers
        let ids = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own,
                  !listed.contains(id), !builtIn.contains(id.lowercased()) else { return nil }
            return id
        }
        return Array(Set(ids)).sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
}

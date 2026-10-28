import AppKit
import SwiftUI
import ClipnpasteCore

struct AboutSection: View {
    static let repository = URL(string: "https://github.com/irfanabdulhameed/clipnpaste")!

    let updater: Updater

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        @Bindable var prefs = updater.prefs
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clipnpaste")
                            .font(.title2.weight(.semibold))
                        Text(version)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                UpdateStatusRows(updater: updater)
                Toggle(isOn: $prefs.checkForUpdates) {
                    Text("Check for updates automatically")
                    Text("Once a day, without interrupting you. A new version shows in the menu-bar menu.")
                }
            }

            Section {
                LabeledContent("Source code") {
                    Button("Open on GitHub") { NSWorkspace.shared.open(Self.repository) }
                        .help(Self.repository.absoluteString)
                }
                LabeledContent("Licence", value: "MIT")
            }
        }
        .formStyle(.grouped)
    }
}

/// The update status, its action, and for some states a second row (notes, progress).
private struct UpdateStatusRows: View {
    let updater: Updater
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// State changes cross-fade; under Reduce Motion they cut, so rows never slide.
    private var animation: Animation? {
        systemReduceMotion || Motion.reduce ? nil : .easeInOut(duration: Motion.quick * DebugFlags.slowMotion)
    }

    var body: some View {
        Group {
            LabeledContent {
                trailing
            } label: {
                title
                subtitle
            }
            .accessibilityElement(children: .contain)
            extraRow
        }
        .animation(animation, value: key)
    }

    /// One value per state (progress excluded), so only real state changes animate.
    private var key: String {
        switch updater.state {
        case .idle: "idle"
        case .checking: "checking"
        case .upToDate: "uptodate"
        case .available(let r): "available \(r.version)"
        case .downloading: "downloading"
        case .installing: "installing"
        case .notPublic: "private"
        case .failed(let m, _): "failed \(m)"
        }
    }

    @ViewBuilder private var title: some View {
        switch updater.state {
        case .idle:
            Text("Updates")
        case .checking:
            Text("Checking for updates…")
        case .upToDate:
            Text("\(icon("checkmark.circle.fill", .green)) You have the latest version.")
        case .available(let release):
            Text("Version \(release.version.description) is available")
                .fontWeight(.semibold)
        case .downloading(let release, _, _):
            Text("Downloading version \(release.version.description)…")
        case .installing(let release):
            Text("Installing version \(release.version.description)…")
        case .notPublic:
            Text("\(icon("info.circle", .secondary)) Updates will be available once the project is public.")
        case .failed(_, let retry):
            Text("\(icon("exclamationmark.triangle.fill", .orange)) \(retry == .check ? "Couldn't check for updates" : "Couldn't install the update")")
        }
    }

    /// A symbol set inline in the title, so the title and its caption keep one left edge.
    private func icon(_ name: String, _ style: some ShapeStyle) -> Text {
        Text(Image(systemName: name)).foregroundStyle(style)
    }

    @ViewBuilder private var subtitle: some View {
        switch updater.state {
        case .idle, .upToDate, .notPublic:
            Text(lastChecked)
        case .checking:
            Text("Asking GitHub for the latest version.")
        case .available:
            Text("You have \(updater.current?.description ?? "an older version").")
        case .downloading(_, let received, let total):
            Text(UpdateText.progress(received: received, total: total))
                .monospacedDigit()
        case .installing:
            Text("Clipnpaste relaunches in a moment. Your clips and settings stay as they are.")
        case .failed(let message, _):
            Text(message)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch updater.state {
        case .idle, .upToDate, .notPublic:
            checkButton
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Checking")
                checkButton.disabled(true)
            }
        case .available:
            Button("Install and relaunch") { updater.install() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Cancel") { updater.cancel() }
        case .installing:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Installing")
        case .failed:
            Button("Retry") { updater.retry() }
        }
    }

    private var checkButton: some View {
        Button("Check for updates") { updater.check() }
            .disabled(updater.current == nil)
            .help(updater.current == nil ? "This build has no version, so it doesn't update." : "Ask GitHub for the latest version")
    }

    @ViewBuilder private var extraRow: some View {
        switch updater.state {
        case .available(let release):
            let lines = ReleaseNotes.excerpt(release.notes)
            if !lines.isEmpty || release.page != nil {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").accessibilityHidden(true)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let page = release.page {
                        Link("Release notes on GitHub", destination: page)
                            .padding(.top, lines.isEmpty ? 0 : 2)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .downloading(_, let received, let total):
            if let total, total > 0 {
                ProgressView(value: Double(min(received, total)), total: Double(total))
                    .accessibilityLabel("Download progress")
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        default:
            EmptyView()
        }
    }

    private var lastChecked: String {
        guard let date = updater.prefs.lastUpdateCheck else { return "Not checked yet." }
        if Date().timeIntervalSince(date) < 60 { return "Checked just now." }
        return "Last checked \(date.formatted(.relative(presentation: .named)))."
    }
}

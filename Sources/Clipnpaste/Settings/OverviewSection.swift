import AppKit
import SwiftUI
import ClipnpasteCore

/// What the Overview needs from the rest of the app. The app delegate sets these at launch.
@MainActor
enum OverviewHooks {
    /// Opens the panel, as the shortcut does.
    static var openPanel: (() -> Void)?
}

/// Settings › Overview: a calm summary of the history, storage against its cap, today's copies,
/// the apps copied from most, the Accessibility permission, and two actions.
struct OverviewSection: View {
    let env: AppEnvironment
    @State private var model: OverviewModel

    init(env: AppEnvironment) {
        self.env = env
        _model = State(initialValue: OverviewModel(store: env.store))
    }

    /// `--settings-preview`: the section around a model the preview has set up.
    init(env: AppEnvironment, model: OverviewModel) {
        self.env = env
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("History") {
                if model.counts.total == 0 {
                    emptyRow
                } else {
                    LabeledContent {
                        Text(ClipsFormat.number(model.counts.total))
                            .monospacedDigit()
                    } label: {
                        Text("Clips")
                        Text(split)
                    }
                    LabeledContent("Copied today") {
                        Text(ClipsFormat.number(model.today))
                            .monospacedDigit()
                    }
                }
                storageRow
            }
            if model.counts.total > 0 {
                Section {
                    if model.topApps.isEmpty {
                        Text("Nothing copied in the last 30 days.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.topApps) { app in appRow(app) }
                    }
                } header: {
                    Text("Top apps")
                } footer: {
                    Text("Clips copied in the last 30 days, by the app they came from.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Permissions") {
                accessibilityRow
            }
            Section {
                HStack(spacing: 8) {
                    Button("Open Panel") { OverviewHooks.openPanel?() }
                        .disabled(OverviewHooks.openPanel == nil)
                        .help("Show the clip panel (the same as the shortcut)")
                    Spacer()
                    Button("Clear History…", role: .destructive) { model.confirmingClear = true }
                        .disabled(model.counts.total == 0)
                        .help("Delete every clip")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            model.start()
            defer { model.stop() }
            // The permission can change in System Settings at any time; the rest follows the store.
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                ticks += 1
                model.refreshPermission()
                if ticks % 30 == 0 { model.refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .modifier(ClipsClearConfirmation(isPresented: $model.confirmingClear, count: model.counts.total) {
            model.store.removeAll()
        })
    }

    /// "1,102 text · 182 images".
    private var split: String {
        let c = model.counts
        return "\(ClipsFormat.number(c.text)) text · \(ClipsFormat.number(c.image)) \(c.image == 1 ? "image" : "images")"
    }

    private var emptyRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("No clips yet")
                Text("Copy something and it shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Image files against the cap, as a plain bar, and the auto-clear setting.
    private var storageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Image storage") {
                Text("\(ClipsFormat.bytes(model.imageBytes)) of \(ClipsFormat.bytes(model.imageCap))")
                    .monospacedDigit()
            }
            ProgressView(value: model.storageFraction)
                .progressViewStyle(.linear)
                .tint(model.storageFraction >= 0.9 ? Color(nsColor: Palette.amber) : .accentColor)
                .accessibilityLabel("Image storage")
                .accessibilityValue("\(Int((model.storageFraction * 100).rounded())) percent of \(ClipsFormat.bytes(model.imageCap)) used")
            Text(storageNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var storageNote: String {
        let age = model.maxAge.map { "Auto-clear after \(ClipsFormat.age($0))." } ?? "Auto-clear is off."
        return "\(age) Past \(ClipsFormat.bytes(model.imageCap)), the oldest images are removed."
    }

    private func appRow(_ app: SourceAppCount) -> some View {
        LabeledContent {
            Text(ClipsFormat.clips(app.count))
                .monospacedDigit()
        } label: {
            Label {
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(nsImage: AppIcons.icon(for: app.bundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
            }
        }
    }

    private var accessibilityRow: some View {
        LabeledContent {
            if model.canPaste {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(nsColor: Palette.amber))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text("Not granted")
                        .foregroundStyle(.secondary)
                    Button("Grant…") { Paster.openAccessibilitySettings() }
                        .help("Open Accessibility in System Settings")
                }
            }
        } label: {
            Text("Accessibility")
            Text(model.canPaste
                 ? "Clipnpaste can paste into the app you were using."
                 : "Return copies only. Allow Clipnpaste in Accessibility to paste.")
        }
    }
}

/// The Overview's numbers, read from the store and refreshed whenever clips change.
@MainActor @Observable
final class OverviewModel {
    @ObservationIgnored let store: any ClipStore
    private(set) var counts = ClipCounts()
    private(set) var imageBytes: Int64 = 0
    private(set) var imageCap: Int64 = SQLiteClipStore.defaultMaxImageBytes
    private(set) var maxAge: TimeInterval?
    private(set) var today = 0
    private(set) var topApps: [SourceAppCount] = []
    private(set) var canPaste = false
    var confirmingClear = false
    /// `--settings-preview`: show a permission state without asking the system.
    @ObservationIgnored var permissionOverride: Bool?
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var queued = false

    init(store: any ClipStore) {
        self.store = store
    }

    var storageFraction: Double {
        guard imageCap > 0 else { return 0 }
        return min(max(Double(imageBytes) / Double(imageCap), 0), 1)
    }

    func start() {
        guard observer == nil else { return }
        observer = store.addObserver { [weak self] _ in self?.queueRefresh() }
        refresh()
    }

    func stop() {
        if let observer { store.removeObserver(observer) }
        observer = nil
    }

    private func queueRefresh() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queued = false
            self.refresh()
        }
    }

    func refresh(now: Date = Date()) {
        counts = store.countsByKind()
        imageBytes = store.storedImageBytes()
        // The live caps are the store's; the settings write the preferences into it.
        imageCap = (store as? SQLiteClipStore)?.maxImageBytes ?? SQLiteClipStore.defaultMaxImageBytes
        maxAge = store.maxAge
        today = store.copies(onDayOf: now)
        topApps = store.topSources(lastDays: 30, now: now, limit: 5)
        refreshPermission()
    }

    func refreshPermission() {
        let granted = permissionOverride ?? Paster.canPost
        if granted != canPaste { canPaste = granted }
    }
}

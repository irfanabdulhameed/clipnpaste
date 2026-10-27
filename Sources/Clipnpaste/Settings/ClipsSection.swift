import AppKit
import SwiftUI
import ClipnpasteCore

/// Settings › Clips: every clip as the panel's cards, with search, a Text / Images filter,
/// multi-select, delete, clear all and a text editor. Pages in as it scrolls.
struct ClipsSection: View {
    let env: AppEnvironment
    @State private var model: ClipsModel
    @State private var searchFocus = 0
    @FocusState private var gridFocus: Bool

    init(env: AppEnvironment) {
        self.env = env
        _model = State(initialValue: ClipsModel(store: env.store, watcher: env.watcher))
    }

    /// `--settings-preview`: the section around a model the preview has set up.
    init(env: AppEnvironment, model: ClipsModel) {
        self.env = env
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            topBar
            Divider()
            content
            Divider()
            bottomBar
        }
        .frame(minWidth: 420, minHeight: 320)
        .task {
            model.start()
            defer { model.stop() }
            // Time labels and the thumbnail cache follow the clock while the section is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { model.reload() }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            model.theme = ClipsModel.liveTheme()
        }
        .onChange(of: gridFocus) { model.gridFocused = gridFocus }
        .sheet(item: $model.editing) { clip in
            ClipsEditor(clip: clip, save: { model.save(clip, text: $0) }, cancel: { model.editing = nil })
        }
        .modifier(ClipsClearConfirmation(isPresented: $model.confirmingClear, count: model.totalCount) {
            model.clearAll()
        })
        .background {
            // ⌘F from anywhere in the section.
            Button("Find") { searchFocus += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    // MARK: Bars

    private var topBar: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            ClipsSearchField(text: $model.query, focusRequest: searchFocus, enabled: !model.isEmptyStore) {
                gridFocus = true
                if model.selection.isEmpty { model.moveCursor(toIndex: 0, extend: false) }
            }
            .frame(minWidth: 160, maxWidth: .infinity)
            Picker("Show", selection: $model.filter) {
                ForEach(ClipsModel.Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.isEmptyStore)
            .help("Show all clips, text only or images only")
        }
        .padding(.horizontal, ClipsModel.inset)
        .padding(.vertical, 12)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(status)
                .font(.system(size: 12))
                .foregroundStyle(model.theme.label2)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 8)
            Button(role: .destructive) {
                model.deleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selection.isEmpty)
            .help(model.selection.isEmpty ? "Select clips to delete them" : "Delete the selected clips (⌘⌫)")
            Button("Clear All…") { model.confirmingClear = true }
                .disabled(model.isEmptyStore || model.phase == .loading)
                .help("Delete every clip")
        }
        .padding(.horizontal, ClipsModel.inset)
        .frame(height: 44)
    }

    /// "1,284 clips", "12 results", "182 images", "3 selected".
    private var status: String {
        if model.phase == .loading { return "Loading…" }
        if model.totalCount == 0 { return "No clips" }
        if !model.selection.isEmpty { return "\(ClipsFormat.number(model.selection.count)) selected" }
        let n = model.matchCount
        if !model.currentQuery.needle.isEmpty { return "\(ClipsFormat.number(n)) \(n == 1 ? "result" : "results")" }
        switch model.filter {
        case .all: return ClipsFormat.clips(n)
        case .text: return "\(ClipsFormat.number(n)) text \(n == 1 ? "clip" : "clips")"
        case .images: return "\(ClipsFormat.number(n)) \(n == 1 ? "image" : "images")"
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.phase == .loading {
            grid(placeholdersOnly: true)
        } else if model.isEmptyStore {
            ClipsMessage(theme: model.theme, symbol: "doc.on.clipboard", title: "No clips yet",
                         detail: "Copy something and it shows up here.")
        } else if model.clips.isEmpty {
            noResults
        } else {
            grid(placeholdersOnly: false)
        }
    }

    @ViewBuilder private var noResults: some View {
        let needle = model.currentQuery.needle
        if needle.isEmpty {
            ClipsMessage(theme: model.theme, symbol: model.filter == .images ? "photo" : "text.alignleft",
                         title: model.filter == .images ? "No images" : "No text clips",
                         detail: "Copied \(model.filter == .images ? "images" : "text") show up here.",
                         action: ("Show All", { model.filter = .all }))
        } else {
            ClipsMessage(theme: model.theme, symbol: "magnifyingglass", title: "No results for “\(needle)”",
                         detail: model.filter == .images ? "Search looks in text, and images have none." : "Check the spelling or try a shorter search.",
                         action: ("Clear Search", { model.query = "" }))
        }
    }

    private func grid(placeholdersOnly: Bool) -> some View {
        let g = ClipsModel.geometry
        let columns = Array(repeating: GridItem(.fixed(CGFloat(g.cardWidth)), spacing: ClipsModel.gap), count: max(model.columns, 1))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: ClipsModel.gap) {
                    if placeholdersOnly {
                        ForEach(0..<max(model.columns * 2, 4), id: \.self) { _ in ClipsPlaceholderCard(theme: model.theme) }
                    } else {
                        ForEach(model.clips) { clip in
                            ClipsCard(clip: clip, model: model) { gridFocus = true }
                                .id(clip.id)
                        }
                        if model.hasMore {
                            // The next page loads when this row comes into view.
                            ForEach(0..<max(model.columns, 1), id: \.self) { i in
                                ClipsPlaceholderCard(theme: model.theme)
                                    .onAppear { if i == 0 { model.loadMore() } }
                            }
                        }
                    }
                }
                .padding(.horizontal, model.sidePadding)
                .padding(.vertical, ClipsModel.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The scroll content's width (less any scroller) sets the columns; leftovers centre the grid.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.layout(width: $0) }
            }
            .background {
                // A click between cards (not on one) clears the selection, as in Finder.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        gridFocus = true
                        model.clearSelection()
                    }
            }
            .focusable(!placeholdersOnly)
            .focused($gridFocus)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                let (handled, target) = model.handleKey(press.key, modifiers: press.modifiers)
                if let target { scroll(proxy, to: target) }
                return handled ? .handled : .ignored
            }
            .accessibilityLabel("Clips")
        }
    }

    /// Keeps the keyboard's card in view, on the panel's `settle` spring (bounce 0); instant under
    /// Reduce Motion.
    private func scroll(_ proxy: ScrollViewProxy, to id: UUID) {
        if Motion.reduce {
            proxy.scrollTo(id)
        } else {
            withAnimation(.spring(duration: Motion.settle * DebugFlags.slowMotion, bounce: 0)) { proxy.scrollTo(id) }
        }
    }
}

/// The empty, no-results and similar messages: a symbol, a line, a hint and maybe one action.
struct ClipsMessage: View {
    let theme: Theme
    let symbol: String
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(theme.label3)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.label)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.label2)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

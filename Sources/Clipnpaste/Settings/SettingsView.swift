import SwiftUI
import ClipnpasteCore

/// The sidebar and the selected section, in the system's own split view.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The list needs an optional selection; a click on empty space never clears it.
    private var selection: Binding<SettingsSection?> {
        Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .overview: OverviewSection(env: model.env)
        case .clips: ClipsSection(env: model.env)
        case .general: GeneralSection(model: model)
        case .panel: PanelSection(prefs: model.prefs)
        case .motion: MotionSection(prefs: model.prefs)
        case .privacy: PrivacySection(env: model.env)
        case .about: AboutSection()
        }
    }
}

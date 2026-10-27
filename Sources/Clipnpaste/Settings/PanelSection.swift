import SwiftUI
import ClipnpasteCore

struct PanelSection: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker(selection: $prefs.panelRows) {
                    Text("1 row").tag(1)
                    Text("2 rows").tag(2)
                    Text("3 rows").tag(3)
                } label: {
                    Text("Height")
                    Text("How tall the panel opens. Dragging its handle, or ⌥↑ and ⌥↓, changes this too.")
                }
                .pickerStyle(.segmented)

                Picker(selection: $prefs.cardButtons) {
                    Text("Hover + selected").tag(Preferences.CardButtons.hoverAndSelected)
                    Text("Always").tag(Preferences.CardButtons.always)
                } label: {
                    Text("Card buttons")
                    Text("When Copy and Remove show on a card.")
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker(selection: $prefs.appearance) {
                    Text("System").tag(Preferences.Appearance.system)
                    Text("Light").tag(Preferences.Appearance.light)
                    Text("Dark").tag(Preferences.Appearance.dark)
                } label: {
                    Text("Appearance")
                    Text("For the panel and this window.")
                }
                .pickerStyle(.segmented)

                Picker(selection: $prefs.glass) {
                    Text("Liquid Glass").tag(Preferences.Glass.liquid)
                    Text("Classic blur").tag(Preferences.Glass.classic)
                    Text("Solid").tag(Preferences.Glass.solid)
                } label: {
                    Text("Glass")
                    Text("Classic blur is the frosted look of earlier macOS. Solid has no transparency.")
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}

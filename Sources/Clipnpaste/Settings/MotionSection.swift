import SwiftUI
import ClipnpasteCore

/// What the panel does while a card is dragged out of it, applied at once.
struct MotionSection: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker(selection: $prefs.dragOut) {
                    Text("Shrink to strip").tag(Preferences.DragOut.strip)
                    Text("Slide away").tag(Preferences.DragOut.slide)
                    Text("Stay").tag(Preferences.DragOut.stay)
                } label: {
                    Text("Panel while dragging out")
                    Text("What the panel does while a card is outside it.")
                }
                .pickerStyle(.segmented)

                Picker(selection: $prefs.afterDrop) {
                    Text("Grow back").tag(Preferences.AfterDrop.growBack)
                    Text("Close").tag(Preferences.AfterDrop.close)
                } label: {
                    Text("After a drop")
                    Text("Once another app takes the card. Grow back keeps the panel open for the next one.")
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}

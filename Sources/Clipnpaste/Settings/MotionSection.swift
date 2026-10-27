import SwiftUI
import ClipnpasteCore

/// The prototype's Decisions drawer, natively: the same choices and labels, applied at once.
struct MotionSection: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker(selection: $prefs.dragTilt) {
                    Text("−6° + speed").tag(Preferences.DragTilt.speed)
                    Text("−45°").tag(Preferences.DragTilt.fixed45)
                } label: {
                    Text("Drag tilt")
                    Text("How a lifted card leans. With speed it leans 6° and swings up to 8° more as you move.")
                }
                .pickerStyle(.segmented)

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

            Section {
                Picker(selection: $prefs.cardPop) {
                    ForEach(Preferences.cardPops, id: \.self) { Text($0.formatted(.number.precision(.fractionLength(2)))).tag($0) }
                } label: {
                    Text("Card pop")
                    Text("How far the selected card grows for a moment.")
                }
                .pickerStyle(.segmented)

                Picker(selection: $prefs.selection) {
                    Text("Sliding highlight").tag(Preferences.Selection.slide)
                    Text("One-frame flip").tag(Preferences.Selection.flip)
                } label: {
                    Text("Selection change")
                    Text("How the highlight reaches the next card.")
                }
                .pickerStyle(.segmented)

                Picker(selection: $prefs.entrance) {
                    Text("12 ms stagger").tag(Preferences.Entrance.stagger)
                    Text("Together").tag(Preferences.Entrance.together)
                } label: {
                    Text("Card entrance")
                    Text("How the cards arrive when the panel opens.")
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker(selection: $prefs.reduceMotion) {
                    Text("Follow system").tag(Preferences.ReduceMotion.system)
                    Text("Always on").tag(Preferences.ReduceMotion.always)
                } label: {
                    Text("Reduce Motion")
                    Text("When on, the panel fades and cuts instead of moving, scaling and tilting.")
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $prefs.slowMotion) {
                    Text("Slow motion ×5")
                    Text("Runs every motion five times slower, to inspect the curves. Turns off when Clipnpaste quits.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

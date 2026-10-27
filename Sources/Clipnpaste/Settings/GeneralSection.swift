import SwiftUI
import ClipnpasteCore

struct GeneralSection: View {
    let model: SettingsModel
    @State private var login = LaunchAtLogin.status
    @State private var loginError: String?

    var body: some View {
        @Bindable var prefs = model.prefs
        let recorder = model.recorder
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        ShortcutRecorderControl(recorder: recorder)
                            .frame(width: 148, height: 24)
                        Button("Reset") { recorder.reset() }
                            .disabled(recorder.isDefault)
                            .help("Reset to \(recorder.defaultLabel)")
                    }
                } label: {
                    Text("Shortcut")
                    Text(recorder.message)
                        .foregroundStyle(recorder.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }

            Section {
                Toggle(isOn: loginBinding) {
                    Text("Launch at login")
                    if let note = loginNote { Text(note) }
                }
                if login == .needsApproval {
                    LabeledContent("Login Items") {
                        Button("Open System Settings…") { LaunchAtLogin.openSettings() }
                    }
                }
            }

            Section {
                Picker(selection: $prefs.openOn) {
                    Text("Screen with the pointer").tag(Preferences.Screen.pointer)
                    Text("Main screen").tag(Preferences.Screen.main)
                } label: {
                    Text("Open the panel on")
                    Text("The main screen is the one with the menu bar.")
                }
            }

            Section {
                Toggle("Show menu-bar icon", isOn: $prefs.showMenuBarIcon)
                Toggle(isOn: $prefs.showInDock) {
                    Text("Show in Dock")
                    Text("With both off, open Clipnpaste again from Applications or Spotlight to come back here.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login = LaunchAtLogin.status }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { login == .enabled || login == .needsApproval },
            set: { on in
                loginError = nil
                do {
                    try LaunchAtLogin.setEnabled(on)
                } catch {
                    loginError = "Couldn't change it: \(error.localizedDescription)"
                }
                login = LaunchAtLogin.status
            })
    }

    private var loginNote: String? {
        if let loginError { return loginError }
        return login == .needsApproval ? "Waiting for your approval in System Settings › Login Items." : nil
    }
}

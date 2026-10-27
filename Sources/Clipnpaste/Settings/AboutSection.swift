import AppKit
import SwiftUI

struct AboutSection: View {
    static let repository = URL(string: "https://github.com/irfanabdulhameed/clipnpaste")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
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

import SwiftUI

struct ClipsSection: View {
    init(env: AppEnvironment) {}

    var body: some View {
        Form { Text("Clips") }.formStyle(.grouped)
    }
}

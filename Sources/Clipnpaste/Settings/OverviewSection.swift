import SwiftUI

struct OverviewSection: View {
    init(env: AppEnvironment) {}

    var body: some View {
        Form { Text("Overview") }.formStyle(.grouped)
    }
}

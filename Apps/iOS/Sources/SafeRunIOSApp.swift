import SafeRunDomain
import SwiftUI

@main
struct SafeRunIOSApp: App {
    var body: some Scene {
        WindowGroup {
            IOSBootstrapView()
        }
    }
}

private struct IOSBootstrapView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.red)

            Text("Safe Run")
                .font(.title.bold())

            Text("iPhone companion")
                .foregroundStyle(.secondary)

            Text("State: \(RunState.idle.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}


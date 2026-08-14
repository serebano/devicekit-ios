import SwiftUI

/// Lean host app that carries the broadcast upload extension and opens the
/// system broadcast picker programmatically so the farm can start the mirror
/// hands-off (`ios_find_and_tap "Start Broadcast"`). It has no other purpose;
/// all capture work lives in the `net.busymate.mirror.upload` extension.
@main
struct BroadcastMirrorApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Busymate Mirror")
                .font(.largeTitle.bold())
            Text("ReplayKit → H.264 → :12005")
                .font(.headline)
                .foregroundStyle(.secondary)
            BroadcastPicker(preferredExtension: BroadcastPicker.uploadExtensionID)
                .frame(width: 120, height: 120)
            Text("Opens the system sheet automatically.\nFarm taps “Start Broadcast”.")
                .multilineTextAlignment(.center)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

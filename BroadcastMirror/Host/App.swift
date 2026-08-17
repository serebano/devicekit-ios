import SwiftUI

/// Lean host app that carries the broadcast upload extension and opens the
/// system broadcast picker programmatically so the farm can start the mirror
/// hands-off (`ios_find_and_tap "Start Broadcast"`). Beyond the picker its only
/// job is to hand the WiFi `authToken` to the extension via the App Group
/// shared container (the standard iOS way an appex receives host config) — the
/// per-device rotation path (busymate-devtools #1759).
@main
struct BroadcastMirrorApp: App {
    init() { SharedMirrorConfig.publishAuthTokenIfConfigured() }
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Writes `mirror-config.json` (with the current `authToken`, and any retune keys)
/// into the App Group container the upload extension reads at `broadcastStarted`.
///
/// DORMANT until an App Group is provisioned: `appGroupID` is `nil` by default, so
/// this is a no-op and the host needs NO `com.apple.security.application-groups`
/// entitlement — the extension then rides its baked `defaultAuthToken`. Phase-2
/// per-device rotation: set `appGroupID` (+ the entitlement on host AND extension,
/// + the group registered on ASC), have the daemon hand this app the per-device
/// secret (launch arg / Documents drop), and the extension picks it up here.
enum SharedMirrorConfig {
    /// Keep in lockstep with `BroadcastConfig.appGroupID` (e.g. `group.net.busymate.mirror`).
    static let appGroupID: String? = nil

    static func publishAuthTokenIfConfigured(token: String? = nil) {
        guard let group = appGroupID,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return }   // App Group off → extension uses its baked default; no entitlement needed.
        let payload: [String: Any] = ["authToken": token ?? provisionedAuthToken()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: dir.appendingPathComponent("mirror-config.json"), options: .atomic)
    }

    /// The per-device secret the daemon provisions (Phase-2 wiring). Until then,
    /// mirror the extension's baked default so a manual App-Group enable still works.
    private static func provisionedAuthToken() -> String { "bmfarm-mirror-7df8d98b9ff9698a7f1a8394" }
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

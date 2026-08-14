import Foundation

/// Tunable knobs for the broadcast mirror. Compile-time defaults are chosen so
/// the current farm fleet streams at its proven-safe native geometry while any
/// Pro/Max framebuffer is capped under the ReplayKit ~50 MB extension ceiling.
///
/// If an App Group is configured (`appGroupID`, off by default — the `:12005`
/// path needs no entitlement), the farm can drop a `mirror-config.json` into the
/// shared container to retune fps / cap / bitrate WITHOUT rebuilding the binary —
/// the remote-manageable posture. Until then the defaults below apply.
struct BroadcastConfig: Equatable {

    /// Cap applied to the long edge of the source frame before encode.
    /// Default 1920: SE (1334) and XR/11 (1792) pass through native; a Pro
    /// (2556) is capped to ~886×1920 (~1.7 Mpx) — inside the spike's measured
    /// safe band (SE 1.0 Mpx ≈ 18 MB RSS, no jetsam). Set 0 to disable capping.
    var maxLongEdge: Int = 1920

    /// Target encode frame rate. ReplayKit delivers ~60; the pacer drops frames
    /// to hold this rate, halving CPU/bitrate/memory at 30. Owner asked 30–60 —
    /// the farm ships 60 (native H.264 hardware-encoded off the display framebuffer).
    var fps: Int = 60

    /// Explicit average bitrate (bits/s). `nil` derives it from geometry × fps.
    var bitrate: Int? = nil

    /// Seconds between forced keyframes (also forced on each new client connect).
    var keyframeIntervalSeconds: Int = 2

    /// Loopback TCP port the producer forwards off-device. THE wire contract.
    var videoPort: UInt16 = 12005

    /// Reserved audio port (Opus). Audio is a stubbed follow-up; see README.
    var audioPort: UInt16 = 12006

    /// App Group for optional file-based config + tee retrieval. `nil` = disabled
    /// (no entitlement required). Set to e.g. `group.net.busymate.mirror` to enable.
    var appGroupID: String? = nil

    static let `default` = BroadcastConfig()

    /// Load defaults, then overlay a `mirror-config.json` from the App Group
    /// container if one exists. Any missing/invalid key keeps its default.
    static func load() -> BroadcastConfig {
        var cfg = BroadcastConfig.default
        guard let group = cfg.appGroupID,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let data = try? Data(contentsOf: dir.appendingPathComponent("mirror-config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return cfg }
        if let v = json["maxLongEdge"] as? Int { cfg.maxLongEdge = v }
        if let v = json["fps"] as? Int, v > 0, v <= 120 { cfg.fps = v }
        if let v = json["bitrate"] as? Int, v > 0 { cfg.bitrate = v }
        if let v = json["keyframeIntervalSeconds"] as? Int, v > 0 { cfg.keyframeIntervalSeconds = v }
        return cfg
    }
}

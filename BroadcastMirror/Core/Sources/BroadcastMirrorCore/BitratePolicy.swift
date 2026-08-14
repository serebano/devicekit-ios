import Foundation

/// Pure bitrate selection for the realtime encoder.
///
/// A fixed bitrate over-spends on a small phone and starves a large one, so the
/// target is derived from the *encoded* pixel count and frame rate, then clamped
/// to a sane band for a browser-side mirror. Kept VideoToolbox-free for testing.
public enum BitratePolicy {

    public static let minBitrate = 1_500_000   // 1.5 Mbps floor
    public static let maxBitrate = 8_000_000   // 8 Mbps ceiling

    /// Average target bitrate (bits/second) for the given encode geometry.
    ///
    /// Uses ~0.09 bits per pixel per second — a good realtime-H.264 operating
    /// point for screen content (lots of flat UI, occasional motion) — then
    /// clamps into `[minBitrate, maxBitrate]`.
    public static func averageBitrate(width: Int, height: Int, fps: Int) -> Int {
        let w = max(0, width), h = max(0, height), f = max(1, fps)
        let pps = Double(w * h * f)
        let raw = Int(pps * 0.09)
        return min(maxBitrate, max(minBitrate, raw))
    }
}

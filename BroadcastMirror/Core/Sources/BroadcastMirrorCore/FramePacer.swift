import Foundation

/// Decimates ReplayKit's ~60 fps delivery down to a target encode rate.
///
/// ReplayKit hands frames at the device refresh rate; encoding every one at 60
/// doubles CPU/bitrate/memory vs a 30 fps mirror. `FramePacer` keeps a frame only
/// once at least one target-interval of presentation time has elapsed since the
/// last kept frame — even pacing without accumulating drift. Pure (operates on
/// PTS seconds) so it is deviceless-testable.
public struct FramePacer {
    private let interval: Double
    private var lastKept: Double = -Double.greatestFiniteMagnitude

    /// - Parameter fps: target frame rate. `<= 0` keeps every frame (no pacing).
    public init(fps: Int) {
        interval = fps > 0 ? 1.0 / Double(fps) : 0
    }

    /// Returns `true` to keep (encode) the frame at `ptsSeconds`, else `false`.
    /// The first frame is always kept. A tiny epsilon absorbs PTS jitter so a
    /// 60→30 halving doesn't alternate keep/drop unevenly.
    public mutating func shouldKeep(ptsSeconds pts: Double) -> Bool {
        if interval <= 0 { return true }
        if pts - lastKept >= interval - (interval * 0.05) {
            lastKept = pts
            return true
        }
        return false
    }
}

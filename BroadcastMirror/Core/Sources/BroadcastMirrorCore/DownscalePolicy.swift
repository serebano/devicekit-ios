import Foundation

/// Pure, side-effect-free resolution math for the broadcast encoder.
///
/// ReplayKit hands the extension a **full native-resolution** `CVPixelBuffer` on
/// every frame. Encoding at full res on a Pro-class device (~1179×2556) pushes the
/// encoder's working set toward the ReplayKit ~50 MB extension memory ceiling and
/// risks a jetsam kill mid-broadcast. Capping the *long edge* before encode keeps
/// the encoder's internal buffers small and the wire bitrate bounded, while the
/// downscaled resolution is self-describing to the producer via the emitted SPS.
///
/// The math is intentionally free of VideoToolbox / CoreVideo so it is trivially
/// unit-testable (see `DownscalePolicyTests`).
public enum DownscalePolicy {

    /// A target encode size plus whether an actual pixel transfer is required.
    public struct Target: Equatable {
        public let width: Int
        public let height: Int
        /// `false` when the source already fits under the cap and only an even-round
        /// was applied — the caller may pass the source straight through.
        public let scaled: Bool
        public init(width: Int, height: Int, scaled: Bool) {
            self.width = width; self.height = height; self.scaled = scaled
        }
    }

    /// Compute the encode target for a source frame.
    ///
    /// - Preserves aspect ratio.
    /// - Never upscales (a source smaller than the cap keeps its size).
    /// - Rounds both dimensions to an even number — H.264 4:2:0 requires even
    ///   width/height, and VideoToolbox rejects odd dimensions.
    /// - Clamps to a minimum of 2 so a degenerate input can never produce 0.
    ///
    /// - Parameters:
    ///   - width: source pixel width (must be > 0 for a meaningful result).
    ///   - height: source pixel height (must be > 0).
    ///   - maxLongEdge: cap applied to `max(width, height)`. A value <= 0 disables
    ///     capping (only the even-round is applied).
    public static func target(width: Int, height: Int, maxLongEdge: Int) -> Target {
        let w = max(0, width)
        let h = max(0, height)
        guard w > 0, h > 0 else { return Target(width: 2, height: 2, scaled: false) }

        let longEdge = max(w, h)
        // No cap, or already within it: keep size, only enforce even dimensions.
        if maxLongEdge <= 0 || longEdge <= maxLongEdge {
            return Target(width: even(w), height: even(h), scaled: false)
        }

        // Scale the long edge down to the cap, aspect-preserved.
        let scale = Double(maxLongEdge) / Double(longEdge)
        let tw = even(Int((Double(w) * scale).rounded()))
        let th = even(Int((Double(h) * scale).rounded()))
        return Target(width: tw, height: th, scaled: true)
    }

    /// Round to the nearest even integer, clamped to a minimum of 2.
    static func even(_ v: Int) -> Int {
        if v <= 2 { return 2 }
        return v - (v % 2)
    }
}

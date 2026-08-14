import Foundation
import VideoToolbox
import CoreVideo
import os

/// Hardware-accelerated, memory-bounded downscaler.
///
/// ReplayKit always delivers a full native-resolution frame; on a Pro/Max device
/// that source plus a full-res encoder session can breach the ~50 MB extension
/// ceiling. `PixelScaler` uses a `VTPixelTransferSession` (the Apple-sanctioned
/// scale/convert path — runs on the video hardware, not the CPU) to resize into a
/// small **pooled** destination buffer, so allocations stay bounded to the target
/// size regardless of source resolution. The emitted SPS then advertises the
/// capped dimensions, so the downscale is self-describing to the `:12005` producer.
final class PixelScaler {
    private let log = Logger(subsystem: BroadcastMirror.subsystem, category: "scaler")
    private let width: Int
    private let height: Int
    private let pixelFormat: OSType
    private var pool: CVPixelBufferPool?
    private var session: VTPixelTransferSession?

    init(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    /// Downscale `source` into a pooled destination sized to this scaler.
    /// Returns `nil` if the transfer session or pool cannot be created — the
    /// caller should then fall back to encoding the source as-is.
    func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard ensureReady() else { return nil }
        var dst: CVPixelBuffer?
        let st = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &dst)
        guard st == kCVReturnSuccess, let out = dst else {
            log.error("pool alloc failed \(st)")
            return nil
        }
        let tr = VTPixelTransferSessionTransferImage(session!, from: source, to: out)
        guard tr == noErr else {
            log.error("transfer failed \(tr)")
            return nil
        }
        return out
    }

    private func ensureReady() -> Bool {
        if session == nil {
            var s: VTPixelTransferSession?
            let st = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &s)
            guard st == noErr, let sess = s else { log.error("VTPixelTransferSessionCreate \(st)"); return false }
            // Matched-aspect resize (DownscalePolicy preserves aspect), high-quality downsample.
            VTSessionSetProperty(sess, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            VTSessionSetProperty(sess, key: kVTPixelTransferPropertyKey_DownsamplingMode, value: kVTDownsamplingMode_Average)
            session = sess
        }
        if pool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            // Cap the pool so a stall can never balloon memory: a couple in flight.
            let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 2]
            var p: CVPixelBufferPool?
            let st = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &p)
            guard st == kCVReturnSuccess, let pp = p else { log.error("CVPixelBufferPoolCreate \(st)"); return false }
            pool = pp
        }
        return true
    }

    func teardown() {
        if let s = session { VTPixelTransferSessionInvalidate(s) }
        session = nil
        pool = nil
    }
}

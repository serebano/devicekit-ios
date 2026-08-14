import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import os

/// Realtime VideoToolbox H.264 encoder for the broadcast mirror.
///
/// - Baseline profile, no B-frames — decoder-friendly for the scrcpy/WebCodecs
///   producer on `:12005`.
/// - Emits **Annex-B** start-code NALs; SPS/PPS re-emitted in-band before every
///   IDR so a late-joining TCP client can decode from the next keyframe.
/// - Downscales large source frames (via `PixelScaler`) to the `DownscalePolicy`
///   target before encode, capping the encoder working set under the ReplayKit
///   ~50 MB ceiling. The emitted SPS advertises the capped dimensions.
/// - `requestKeyframe()` forces an IDR on the next frame — used on a new client
///   connect so reconnecting producers/viewers sync immediately.
///
/// The AVCC→Annex-B and NAL-type logic conforms to `BroadcastMirrorCore.AnnexB`,
/// which is the unit-tested spec (see `AnnexBTests`).
final class H264Encoder {
    private let log = Logger(subsystem: BroadcastMirror.subsystem, category: "encoder")
    private let config: BroadcastConfig

    private var session: VTCompressionSession?
    private var scaler: PixelScaler?
    private var srcWidth: Int32 = 0        // last SOURCE dims (session keyed on these)
    private var srcHeight: Int32 = 0
    private var target = DownscalePolicy.Target(width: 0, height: 0, scaled: false)

    private var spsPps: Data?              // cached Annex-B SPS+PPS
    private var sentConfig = false
    private let pendingKeyframeLock = NSLock()
    private var pendingKeyframe = false

    /// Called on the encode thread with a chunk of Annex-B bytes.
    /// `isConfig` marks the SPS/PPS chunk; `isKeyframe` marks an IDR slice.
    var onNAL: ((Data, _ isKeyframe: Bool, _ isConfig: Bool) -> Void)?

    init(config: BroadcastConfig) { self.config = config }

    /// Ask the encoder to emit an IDR on the next frame (reconnect resync).
    func requestKeyframe() {
        pendingKeyframeLock.lock(); pendingKeyframe = true; pendingKeyframeLock.unlock()
    }

    private func takePendingKeyframe() -> Bool {
        pendingKeyframeLock.lock(); defer { pendingKeyframeLock.unlock() }
        let v = pendingKeyframe; pendingKeyframe = false; return v
    }

    /// Feed one source `CVPixelBuffer` (native ReplayKit resolution) at `pts`.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool = false) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        guard ensureSession(sourceW: w, sourceH: h), let sess = session else { return }

        // Downscale to the encode target if the source exceeds the cap.
        let toEncode: CVPixelBuffer = target.scaled ? (scaler?.scale(pixelBuffer) ?? pixelBuffer) : pixelBuffer

        let key = forceKeyframe || takePendingKeyframe()
        var props: CFDictionary?
        if key { props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary }

        VTCompressionSessionEncodeFrame(
            sess, imageBuffer: toEncode, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sb = sampleBuffer else { return }
            self?.handleEncoded(sb)
        }
    }

    private func ensureSession(sourceW w: Int32, sourceH h: Int32) -> Bool {
        if session != nil, w == srcWidth, h == srcHeight { return true }
        teardown()
        srcWidth = w; srcHeight = h
        target = DownscalePolicy.target(width: Int(w), height: Int(h), maxLongEdge: config.maxLongEdge)
        let tw = Int32(target.width), th = Int32(target.height)

        if target.scaled {
            scaler = PixelScaler(width: target.width, height: target.height)
        } else {
            scaler = nil
        }

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: tw, height: th,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let sess = s else { log.error("VTCompressionSessionCreate \(st)"); return false }

        let bitrate = config.bitrate ?? BitratePolicy.averageBitrate(width: target.width, height: target.height, fps: config.fps)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: config.fps * config.keyframeIntervalSeconds))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: config.fps))
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTCompressionSessionPrepareToEncodeFrames(sess)
        session = sess
        sentConfig = false
        spsPps = nil
        log.info("encoder \(w)x\(h) -> \(tw)x\(th) scaled=\(self.target.scaled) @\(self.config.fps)fps \(bitrate)bps")
        return true
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb) else { return }
        let keyframe = !cmSampleIsNotSync(sb)
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sb) {
            if let cfg = Self.annexBParameterSets(fmt), !sentConfig {
                spsPps = cfg; sentConfig = true
                onNAL?(cfg, false, true)
            } else if let cfg = spsPps {
                onNAL?(cfg, false, true)   // repeat config ahead of every IDR
            }
        }
        if let annexB = Self.avccToAnnexB(sb) {
            onNAL?(annexB, keyframe, false)
        }
    }

    private func cmSampleIsNotSync(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false),
              CFArrayGetCount(arr) > 0 else { return false }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        var val: UnsafeRawPointer?
        if CFDictionaryGetValueIfPresent(dict, key, &val), let v = val {
            return CFBooleanGetValue(unsafeBitCast(v, to: CFBoolean.self))
        }
        return false
    }

    /// SPS/PPS from the format description's avcC, as Annex-B (4-byte start codes).
    static func annexBParameterSets(_ fmt: CMFormatDescription) -> Data? {
        var count = 0
        var nalHeaderLen: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLen) == noErr, count > 0
        else { return nil }
        var out = Data()
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = ptr {
                out.append(contentsOf: AnnexB.startCode)
                out.append(p, count: size)
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Convert the VideoToolbox AVCC block buffer into Annex-B. Copies the (small)
    /// encoded frame once, then delegates to the unit-tested `AnnexB.fromAVCC`.
    static func avccToAnnexB(_ sb: CMSampleBuffer) -> Data? {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var length = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &dataPtr) == noErr,
              let base = dataPtr, length > 0 else { return nil }
        let bytes = base.withMemoryRebound(to: UInt8.self, capacity: length) {
            [UInt8](UnsafeBufferPointer(start: $0, count: length))
        }
        return AnnexB.fromAVCC(bytes, lengthSize: 4).map { Data($0) }
    }

    func teardown() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
        scaler?.teardown()
        scaler = nil
    }
}

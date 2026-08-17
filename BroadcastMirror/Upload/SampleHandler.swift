import ReplayKit
import CoreMedia
import Foundation
import os

/// ReplayKit broadcast upload extension — the production farm mirror.
///
/// Pipeline: each ReplayKit video sample → `FramePacer` (60→target fps) →
/// `MemoryPressureGuard` (shed under pressure) → `H264Encoder` (downscale +
/// Baseline H.264 Annex-B) → `MirrorServer` (`:12005` fan-out over USB loopback
/// AND — as of v0.3.0, #1759 — auth-gated WiFi). A new client is primed with
/// cached SPS/PPS and triggers a forced IDR so reconnecting producers/viewers
/// sync at the next frame. Audio is a documented stub (see the `:12006`
/// follow-up in README); video is the priority.
///
/// Bundle id: `net.busymate.mirror.upload` (host `net.busymate.mirror`).
class SampleHandler: RPBroadcastSampleHandler {
    private let log = Logger(subsystem: BroadcastMirror.subsystem, category: "handler")
    private let config = BroadcastConfig.load()
    private lazy var encoder = H264Encoder(config: config)
    private lazy var server = MirrorServer(port: config.videoPort,
                                           authToken: config.authToken,
                                           wifiEnabled: config.wifiEnabled)
    private let memGuard = MemoryPressureGuard()
    private lazy var pacer = FramePacer(fps: config.fps)

    private var firstEncodedFramePending = true
    private var framesIn = 0
    private var framesEncoded = 0
    private var bytesOut = 0
    private var keyframes = 0
    private var startWall = Date()
    private var lastLog = Date()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        log.info("broadcastStarted cap=\(self.config.maxLongEdge) fps=\(self.config.fps) port=\(self.config.videoPort)")
        startWall = Date()
        firstEncodedFramePending = true
        memGuard.start()
        server.onClientConnected = { [weak self] in self?.encoder.requestKeyframe() }
        encoder.onNAL = { [weak self] data, isKeyframe, isConfig in
            guard let self else { return }
            if isConfig { self.server.setConfig(data) }
            // v0.3.1 (#1763): mark config so a slow client's bounded queue never sheds the SPS/PPS.
            self.server.broadcast(data, isConfig: isConfig)
            self.bytesOut += data.count
            if isKeyframe { self.keyframes += 1 }
            if !isConfig { self.framesEncoded += 1 }
        }
        server.start()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            framesIn += 1
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            // Rate-shape first (cheap), then shed under memory pressure, then encode.
            guard pacer.shouldKeep(ptsSeconds: CMTimeGetSeconds(pts)) else { return }
            guard memGuard.shouldEncode() else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let forceKey = firstEncodedFramePending
            firstEncodedFramePending = false
            encoder.encode(pixelBuffer, pts: pts, forceKeyframe: forceKey)
            logStatsThrottled()

        case .audioApp, .audioMic:
            // STUB — audio (:12006 Opus) is a flagged follow-up. iOS has no system
            // Opus encoder; AAC-LC via AVAudioConverter is the cheap alternative if
            // audio is wanted later. See README "Audio (:12006)".
            return

        @unknown default:
            return
        }
    }

    override func broadcastPaused() { log.info("broadcastPaused") }

    override func broadcastResumed() {
        log.info("broadcastResumed — forcing keyframe for resync")
        encoder.requestKeyframe()
    }

    override func broadcastFinished() {
        log.info("broadcastFinished in=\(self.framesIn) enc=\(self.framesEncoded) kf=\(self.keyframes) bytes=\(self.bytesOut)")
        encoder.teardown()
        server.stop()
        memGuard.stop()
    }

    private func logStatsThrottled() {
        guard Date().timeIntervalSince(lastLog) > 2.0 else { return }
        lastLog = Date()
        let secs = max(0.001, Date().timeIntervalSince(startWall))
        log.info("mirror in=\(self.framesIn) enc=\(self.framesEncoded) kf=\(self.keyframes) bytes=\(self.bytesOut) clients=\(self.server.clientCount) mem=\(self.memGuard.level.rawValue) fpsOut=\(String(format: "%.1f", Double(self.framesEncoded)/secs))")
    }
}

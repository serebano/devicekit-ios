import XCTest
@testable import BroadcastMirrorCore

final class FramePacerTests: XCTestCase {

    // 60 fps source paced to 30 fps: keep every other frame (~30 kept per second).
    func test60to30KeepsHalf() {
        var pacer = FramePacer(fps: 30)
        var kept = 0
        for i in 0..<120 { // 2 seconds of 60 fps
            if pacer.shouldKeep(ptsSeconds: Double(i) / 60.0) { kept += 1 }
        }
        XCTAssertEqual(kept, 60, "30 fps over 2 s ≈ 60 kept from 120 delivered")
    }

    // 60 fps source paced to 60 fps: keep everything.
    func test60to60KeepsAll() {
        var pacer = FramePacer(fps: 60)
        var kept = 0
        for i in 0..<60 { if pacer.shouldKeep(ptsSeconds: Double(i) / 60.0) { kept += 1 } }
        XCTAssertEqual(kept, 60)
    }

    // fps <= 0 disables pacing (keep all).
    func testZeroFpsKeepsAll() {
        var pacer = FramePacer(fps: 0)
        var kept = 0
        for i in 0..<50 { if pacer.shouldKeep(ptsSeconds: Double(i) / 60.0) { kept += 1 } }
        XCTAssertEqual(kept, 50)
    }

    // The very first frame is always kept regardless of its PTS.
    func testFirstFrameAlwaysKept() {
        var pacer = FramePacer(fps: 30)
        XCTAssertTrue(pacer.shouldKeep(ptsSeconds: 123.456))
    }

    // A 24 fps source paced to 30 keeps everything (never fabricates frames).
    func testSlowerSourceKeepsAll() {
        var pacer = FramePacer(fps: 30)
        var kept = 0
        for i in 0..<24 { if pacer.shouldKeep(ptsSeconds: Double(i) / 24.0) { kept += 1 } }
        XCTAssertEqual(kept, 24)
    }
}

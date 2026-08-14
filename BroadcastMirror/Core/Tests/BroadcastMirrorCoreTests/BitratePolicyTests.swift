import XCTest
@testable import BroadcastMirrorCore

final class BitratePolicyTests: XCTestCase {

    func testScalesWithPixelsAndFps() {
        let small = BitratePolicy.averageBitrate(width: 640, height: 360, fps: 30)
        let large = BitratePolicy.averageBitrate(width: 1280, height: 720, fps: 30)
        XCTAssertGreaterThan(large, small, "more pixels -> more bits")

        let slow = BitratePolicy.averageBitrate(width: 1280, height: 720, fps: 30)
        let fast = BitratePolicy.averageBitrate(width: 1280, height: 720, fps: 60)
        XCTAssertGreaterThanOrEqual(fast, slow, "more fps -> at least as many bits")
    }

    func testClampedToBand() {
        // A tiny frame clamps up to the floor.
        XCTAssertEqual(BitratePolicy.averageBitrate(width: 64, height: 64, fps: 30),
                       BitratePolicy.minBitrate)
        // A huge frame clamps down to the ceiling.
        XCTAssertEqual(BitratePolicy.averageBitrate(width: 4096, height: 2160, fps: 60),
                       BitratePolicy.maxBitrate)
    }

    func testDegenerateFpsDoesNotDivideByZero() {
        let b = BitratePolicy.averageBitrate(width: 1280, height: 720, fps: 0)
        XCTAssertEqual(b, BitratePolicy.averageBitrate(width: 1280, height: 720, fps: 1))
        XCTAssertGreaterThanOrEqual(b, BitratePolicy.minBitrate)
    }

    // The capped SE (750x1334@30) target stays inside the band — sanity for the
    // proven spike geometry.
    func testSEGeometryInBand() {
        let b = BitratePolicy.averageBitrate(width: 750, height: 1334, fps: 30)
        XCTAssertGreaterThanOrEqual(b, BitratePolicy.minBitrate)
        XCTAssertLessThanOrEqual(b, BitratePolicy.maxBitrate)
    }
}

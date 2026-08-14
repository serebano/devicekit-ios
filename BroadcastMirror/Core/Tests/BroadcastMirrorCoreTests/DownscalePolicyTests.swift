import XCTest
@testable import BroadcastMirrorCore

final class DownscalePolicyTests: XCTestCase {

    // The default cap (1920 long edge) passes the entire current farm fleet
    // through at native geometry — the spike's proven-safe path — with no scale.
    // SE 750x1334, XR/11 828x1792 all have a long edge <= 1920.
    func testCurrentFarmFleetPassesThroughAtDefaultCap() {
        for (w, h) in [(750, 1334), (828, 1792), (1334, 750), (1792, 828)] {
            let t = DownscalePolicy.target(width: w, height: h, maxLongEdge: 1920)
            XCTAssertFalse(t.scaled, "\(w)x\(h) is under the 1920 cap; no scale expected")
            XCTAssertEqual(t.width, w)
            XCTAssertEqual(t.height, h)
        }
    }

    // The flagged production risk: a Pro-class portrait frame is capped on its
    // LONG edge at the default 1920, aspect preserved, and flagged as scaled.
    func testProPortraitCapsLongEdgeAtDefault() {
        let t = DownscalePolicy.target(width: 1179, height: 2556, maxLongEdge: 1920)
        XCTAssertTrue(t.scaled)
        XCTAssertEqual(t.height, 1920, "long edge capped to 1920")
        // 1179 * (1920/2556) = 885.7 -> 886 (even).
        XCTAssertEqual(t.width, 886)
        XCTAssertLessThanOrEqual(max(t.width, t.height), 1920)
    }

    // A lower configurable cap (1280) downscales even the SE — proving the cap is
    // honoured, so the farm can dial memory/bandwidth down for a hot device.
    func testLowerCapDownscalesSmallDevice() {
        let t = DownscalePolicy.target(width: 750, height: 1334, maxLongEdge: 1280)
        XCTAssertTrue(t.scaled)
        XCTAssertEqual(t.height, 1280)
        XCTAssertEqual(t.width, 720) // 750 * 1280/1334 = 719.6 -> 720 (even)
    }

    func testLandscapeCapsWidthAsLongEdge() {
        let t = DownscalePolicy.target(width: 2556, height: 1179, maxLongEdge: 1920)
        XCTAssertTrue(t.scaled)
        XCTAssertEqual(t.width, 1920)
        XCTAssertEqual(t.height, 886)
    }

    // Both output dimensions must always be even (H.264 4:2:0 / VideoToolbox).
    func testOutputDimensionsAlwaysEven() {
        for (w, h) in [(1125, 2436), (828, 1792), (1179, 2556), (1290, 2796), (1284, 2778)] {
            for cap in [720, 1080, 1280, 1600] {
                let t = DownscalePolicy.target(width: w, height: h, maxLongEdge: cap)
                XCTAssertEqual(t.width % 2, 0, "width even for \(w)x\(h)@\(cap)")
                XCTAssertEqual(t.height % 2, 0, "height even for \(w)x\(h)@\(cap)")
                XCTAssertLessThanOrEqual(max(t.width, t.height), max(cap, max(w, h)))
            }
        }
    }

    // Never upscale a small source, even with a generous cap.
    func testNeverUpscales() {
        let t = DownscalePolicy.target(width: 640, height: 480, maxLongEdge: 4096)
        XCTAssertFalse(t.scaled)
        XCTAssertEqual(t.width, 640)
        XCTAssertEqual(t.height, 480)
    }

    // A zero cap disables capping (only the even-round is applied).
    func testZeroCapDisablesCapping() {
        let t = DownscalePolicy.target(width: 1179, height: 2557, maxLongEdge: 0)
        XCTAssertFalse(t.scaled)
        XCTAssertEqual(t.width, 1178) // 1179 -> even
        XCTAssertEqual(t.height, 2556) // 2557 -> even
    }

    // Degenerate inputs can never yield a zero / negative dimension.
    func testDegenerateInputsClampToMinimum() {
        XCTAssertEqual(DownscalePolicy.target(width: 0, height: 0, maxLongEdge: 1280),
                       DownscalePolicy.Target(width: 2, height: 2, scaled: false))
        XCTAssertEqual(DownscalePolicy.even(1), 2)
        XCTAssertEqual(DownscalePolicy.even(-5), 2)
        XCTAssertEqual(DownscalePolicy.even(3), 2)
    }
}

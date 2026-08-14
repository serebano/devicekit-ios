import XCTest
@testable import BroadcastMirrorCore

final class AnnexBTests: XCTestCase {

    // AVCC (4-byte big-endian length prefix) -> Annex-B start codes, preserving
    // NAL payloads exactly. This is the wire conversion the :12005 producer relies on.
    func testAVCCToAnnexBSingleNAL() {
        // length=3, payload = 0x65 (IDR) 0xAA 0xBB
        let avcc: [UInt8] = [0x00, 0x00, 0x00, 0x03, 0x65, 0xAA, 0xBB]
        let out = AnnexB.fromAVCC(avcc)!
        XCTAssertEqual(out, [0x00, 0x00, 0x00, 0x01, 0x65, 0xAA, 0xBB])
    }

    func testAVCCToAnnexBMultipleNALs() {
        // NAL1 len=1 (0x41 non-IDR), NAL2 len=2 (0x01 0x02)
        let avcc: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x41,
                             0x00, 0x00, 0x00, 0x02, 0x01, 0x02]
        let out = AnnexB.fromAVCC(avcc)!
        XCTAssertEqual(out, [0x00, 0x00, 0x00, 0x01, 0x41,
                             0x00, 0x00, 0x00, 0x01, 0x01, 0x02])
        // Round-trips back to the two payloads.
        let nals = AnnexB.splitNALs(out)
        XCTAssertEqual(nals.count, 2)
        XCTAssertEqual(nals[0], [0x41])
        XCTAssertEqual(nals[1], [0x01, 0x02])
    }

    // A truncated final length field must not read out of bounds; the valid
    // prefix is still returned.
    func testTruncatedTailIsSafe() {
        let avcc: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x41, 0x00, 0x00] // dangling
        let out = AnnexB.fromAVCC(avcc)!
        XCTAssertEqual(out, [0x00, 0x00, 0x00, 0x01, 0x41])
    }

    func testEmptyAndBadLengthSizeReturnNil() {
        XCTAssertNil(AnnexB.fromAVCC([]))
        XCTAssertNil(AnnexB.fromAVCC([0x00, 0x00, 0x00, 0x03, 0x65], lengthSize: 3))
    }

    // NAL type classification used to gate config-before-IDR + keyframe detection.
    func testNalTypeAndContains() {
        let sps: [UInt8] = [0x67, 0x42] // type 7
        let pps: [UInt8] = [0x68, 0xCE] // type 8
        let idr: [UInt8] = [0x65, 0x88] // type 5
        let p:   [UInt8] = [0x41, 0x9A] // type 1
        XCTAssertEqual(AnnexB.nalType(sps), 7)
        XCTAssertEqual(AnnexB.nalType(pps), 8)
        XCTAssertEqual(AnnexB.nalType(idr), 5)
        XCTAssertEqual(AnnexB.nalType(p), 1)

        // A config chunk (SPS+PPS) followed by an IDR — the exact shape the
        // encoder emits before every keyframe.
        var stream: [UInt8] = []
        for nal in [sps, pps, idr] { stream += AnnexB.startCode + nal }
        XCTAssertTrue(AnnexB.containsParameterSets(stream))
        XCTAssertTrue(AnnexB.containsIDR(stream))

        // A P-frame chunk carries neither.
        let pOnly = AnnexB.startCode + p
        XCTAssertFalse(AnnexB.containsParameterSets(pOnly))
        XCTAssertFalse(AnnexB.containsIDR(pOnly))
    }

    // 3-byte start codes are also parsed (defensive; VT emits 4-byte).
    func testThreeByteStartCodeSplit() {
        let stream: [UInt8] = [0x00, 0x00, 0x01, 0x67, 0x42,
                               0x00, 0x00, 0x00, 0x01, 0x68, 0xCE]
        let nals = AnnexB.splitNALs(stream)
        XCTAssertEqual(nals.count, 2)
        XCTAssertEqual(AnnexB.nalType(nals[0]), 7)
        XCTAssertEqual(AnnexB.nalType(nals[1]), 8)
    }
}

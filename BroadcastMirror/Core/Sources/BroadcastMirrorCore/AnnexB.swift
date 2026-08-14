import Foundation

/// Pure H.264 NAL byte-format helpers shared by the encoder and the tests.
///
/// VideoToolbox emits **AVCC** (a.k.a. length-prefixed) sample data: each NAL is
/// preceded by a big-endian length field (4 bytes by default). The producer on
/// `:12005` expects **Annex-B**: each NAL preceded by a `00 00 00 01` start code,
/// with in-band SPS/PPS re-emitted before every IDR. This enum is the single,
/// testable source of truth for that conversion and for NAL inspection.
public enum AnnexB {

    /// The 4-byte Annex-B start code.
    public static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    /// Convert a length-prefixed (AVCC) buffer into Annex-B start-code NAL units.
    ///
    /// - Parameters:
    ///   - avcc: the raw AVCC bytes (one or more `<length><nal>` records).
    ///   - lengthSize: bytes in the big-endian length prefix (1, 2, or 4; VT uses 4).
    /// - Returns: Annex-B bytes, or `nil` if the buffer is malformed / empty.
    public static func fromAVCC(_ avcc: [UInt8], lengthSize: Int = 4) -> [UInt8]? {
        guard lengthSize == 1 || lengthSize == 2 || lengthSize == 4 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(avcc.count + 16)
        var i = 0
        let n = avcc.count
        while i + lengthSize <= n {
            var len = 0
            for k in 0..<lengthSize { len = (len << 8) | Int(avcc[i + k]) }
            i += lengthSize
            if len <= 0 || i + len > n { return out.isEmpty ? nil : out } // truncated tail
            out.append(contentsOf: startCode)
            out.append(contentsOf: avcc[i..<(i + len)])
            i += len
        }
        return out.isEmpty ? nil : out
    }

    /// Data overload of `fromAVCC(_:lengthSize:)`.
    public static func fromAVCC(_ avcc: Data, lengthSize: Int = 4) -> Data? {
        fromAVCC([UInt8](avcc), lengthSize: lengthSize).map { Data($0) }
    }

    /// Split an Annex-B buffer into its constituent NAL payloads (start codes
    /// stripped). Accepts both 3- and 4-byte start codes.
    public static func splitNALs(_ bytes: [UInt8]) -> [[UInt8]] {
        var nals: [[UInt8]] = []
        let n = bytes.count
        var i = 0
        var nalStart = -1
        func isStart(_ p: Int) -> Int {
            if p + 3 < n, bytes[p] == 0, bytes[p+1] == 0, bytes[p+2] == 0, bytes[p+3] == 1 { return 4 }
            if p + 2 < n, bytes[p] == 0, bytes[p+1] == 0, bytes[p+2] == 1 { return 3 }
            return 0
        }
        while i < n {
            let sc = isStart(i)
            if sc > 0 {
                if nalStart >= 0, i > nalStart { nals.append(Array(bytes[nalStart..<i])) }
                i += sc
                nalStart = i
            } else {
                i += 1
            }
        }
        if nalStart >= 0, nalStart < n { nals.append(Array(bytes[nalStart..<n])) }
        return nals
    }

    /// The H.264 `nal_unit_type` (low 5 bits of the first NAL byte).
    /// 5 = IDR slice, 1 = non-IDR slice, 7 = SPS, 8 = PPS.
    public static func nalType(_ nal: [UInt8]) -> Int {
        guard let first = nal.first else { return -1 }
        return Int(first & 0x1F)
    }

    /// True if the Annex-B buffer contains at least one SPS (7) and one PPS (8).
    public static func containsParameterSets(_ bytes: [UInt8]) -> Bool {
        let types = splitNALs(bytes).map(nalType)
        return types.contains(7) && types.contains(8)
    }

    /// True if the Annex-B buffer contains an IDR (keyframe) slice (type 5).
    public static func containsIDR(_ bytes: [UInt8]) -> Bool {
        splitNALs(bytes).map(nalType).contains(5)
    }
}

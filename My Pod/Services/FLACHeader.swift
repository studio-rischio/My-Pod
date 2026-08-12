import Foundation

/// Minimal FLAC STREAMINFO reader — just enough to get playing time.
///
/// We need durations at scan time so the Music tab can predict how much space
/// a FLAC album will occupy *after* transcoding to AAC 256k, rather than
/// budgeting against the (roughly 3× larger) source file. Decoding via
/// AVFoundation would mean opening every file in the library on every scan;
/// STREAMINFO lives in the first 26 bytes, so this reads those and stops.
///
/// FLAC guarantees STREAMINFO is the first metadata block, so no block walking
/// is needed. Anything that isn't a well-formed FLAC returns 0 ("unknown"),
/// which callers fall back to a per-format size ratio for.
nonisolated enum FLACHeader {
    /// Bytes of header we need: 4 magic + 4 block header + 18 into STREAMINFO.
    private static let headerLength = 26

    static func durationMS(of url: URL) -> Int {
        guard url.pathExtension.lowercased() == "flac" else { return 0 }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerLength),
              data.count == headerLength else { return 0 }

        let bytes = [UInt8](data)
        guard bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else {
            return 0   // not "fLaC"
        }
        // Low 7 bits of the block header are the block type; 0 = STREAMINFO.
        guard bytes[4] & 0x7F == 0 else { return 0 }

        // STREAMINFO body starts at byte 8. Sample rate and total sample count
        // begin 10 bytes in, packed as:
        //   20 bits sample rate | 3 bits channels-1 | 5 bits bps-1 | 36 bits samples
        var packed: UInt64 = 0
        for byte in bytes[18..<26] {
            packed = (packed << 8) | UInt64(byte)
        }
        let sampleRate = packed >> 44
        let totalSamples = packed & 0x0F_FFFF_FFFF

        guard sampleRate > 0, totalSamples > 0 else { return 0 }
        return Int((totalSamples &* 1000) / sampleRate)
    }
}

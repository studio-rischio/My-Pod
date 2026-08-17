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

    nonisolated struct StreamInfo: Sendable, Equatable {
        var sampleRate = 0
        var bitDepth = 0
        var durationMS = 0
    }

    /// Sample rate, bit depth and playing time in one read. Any field is 0 when
    /// the file isn't a well-formed FLAC or STREAMINFO didn't state it.
    static func streamInfo(of url: URL) -> StreamInfo {
        guard url.pathExtension.lowercased() == "flac" else { return StreamInfo() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return StreamInfo() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerLength),
              data.count == headerLength else { return StreamInfo() }

        let bytes = [UInt8](data)
        guard bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else {
            return StreamInfo()   // not "fLaC"
        }
        // Low 7 bits of the block header are the block type; 0 = STREAMINFO.
        guard bytes[4] & 0x7F == 0 else { return StreamInfo() }

        // STREAMINFO body starts at byte 8. Sample rate, channels, bits per
        // sample and total sample count begin 10 bytes in, packed as:
        //   20 bits sample rate | 3 bits channels-1 | 5 bits bps-1 | 36 bits samples
        var packed: UInt64 = 0
        for byte in bytes[18..<26] {
            packed = (packed << 8) | UInt64(byte)
        }
        let sampleRate = packed >> 44
        let bitDepth = ((packed >> 36) & 0x1F) &+ 1     // stored as bps-1
        let totalSamples = packed & 0x0F_FFFF_FFFF

        guard sampleRate > 0 else { return StreamInfo() }
        return StreamInfo(
            sampleRate: Int(sampleRate),
            bitDepth: Int(bitDepth),
            // A rate with no sample count still tells the encoder what to target.
            durationMS: totalSamples > 0 ? Int((totalSamples &* 1000) / sampleRate) : 0
        )
    }

    static func durationMS(of url: URL) -> Int {
        streamInfo(of: url).durationMS
    }
}

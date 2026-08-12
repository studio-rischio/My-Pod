import AudioToolbox
import Foundation

/// Reads an audio file's real format out of its header.
///
/// The library scanner classifies files by extension, which is free but blind:
/// a 24-bit/96 kHz ALAC and a 256 kbps AAC are both `.m4a`, and only one of
/// them plays correctly on click-wheel hardware. This opens the file and asks
/// CoreAudio what is actually inside.
///
/// AudioToolbox rather than AVFoundation on purpose — `AudioFileOpenURL` is
/// synchronous, so it drops straight into `LibraryScanner.scanSync` without
/// making the whole scan async, and it reads only the header rather than
/// building an asset graph.
///
/// `nonisolated` because scanning runs on a detached task — overrides the
/// project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated enum AudioProbe {
    nonisolated struct Format: Sendable, Equatable {
        /// Effective output rate — the highest across every codec layer, not
        /// the core's rate. HE-AAC stores a half-rate AAC-LC core (22050 Hz for
        /// 44.1 kHz output) and reconstructs the top octave with SBR, so the
        /// core's rate understates what the file actually plays at.
        let sampleRate: Int          // Hz, 0 when unknown
        /// The core/data format, i.e. what a decoder without SBR would hear.
        let formatID: AudioFormatID
        /// Every codec layer present, including `formatID`. HE-AAC appears here
        /// as `aach`/`aacp` even though the data format reports plain `aac` —
        /// the only place the profile is visible.
        let layers: Set<AudioFormatID>
        let bitDepth: Int            // bits per channel, 0 when unknown
        let durationMS: Int          // 0 when unknown

        /// For log lines — enough to explain why a file was flagged.
        var summary: String {
            // Name the most specific layer: an HE file should read "HE-AAC",
            // not the "AAC-LC" its core claims to be.
            let significant = layers.first { $0 != formatID && $0 != kAudioFormatLinearPCM } ?? formatID
            let codec = switch significant {
            case kAudioFormatAppleLossless:  "ALAC"
            case kAudioFormatLinearPCM:      "PCM"
            case kAudioFormatMPEG4AAC:       "AAC-LC"
            case kAudioFormatMPEG4AAC_HE:    "HE-AAC"
            case kAudioFormatMPEG4AAC_HE_V2: "HE-AAC v2"
            case kAudioFormatMPEGLayer3:     "MP3"
            default:                         "codec \(significant)"
            }
            let depth = bitDepth > 0 ? "/\(bitDepth)-bit" : ""
            return "\(codec) \(sampleRate) Hz\(depth)"
        }
    }

    /// Returns nil when the file can't be opened or has no readable format —
    /// callers treat that as "leave it alone" rather than "convert it", so an
    /// unreadable or DRM'd file keeps today's behaviour instead of being
    /// needlessly re-encoded.
    static func read(_ url: URL) -> Format? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr,
              let fileID else { return nil }
        defer { AudioFileClose(fileID) }

        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &asbdSize, &asbd) == noErr
        else { return nil }

        var seconds = Float64(0)
        var secondsSize = UInt32(MemoryLayout<Float64>.size)
        // Best-effort: a failure here just means we fall back to the per-format
        // size ratio when budgeting space.
        _ = AudioFileGetProperty(fileID, kAudioFilePropertyEstimatedDuration, &secondsSize, &seconds)

        let layers = formatLayers(fileID)
        let rates = [asbd.mSampleRate] + layers.map(\.mSampleRate)

        return Format(
            sampleRate: Int((rates.max() ?? 0).rounded()),
            formatID: asbd.mFormatID,
            layers: Set(layers.map(\.mFormatID)).union([asbd.mFormatID]),
            bitDepth: bitDepth(of: asbd),
            durationMS: seconds.isFinite && seconds > 0 ? Int(seconds * 1000) : 0
        )
    }

    /// Every codec layer CoreAudio reports for the file. Needed because the
    /// data format describes only the decodable core: an HE-AAC file reports
    /// plain `aac` there, and admits to `aach` only in the format list.
    ///
    /// The property's size is an upper bound and the tail comes back zeroed,
    /// so entries with no format ID are dropped rather than trusted as a count.
    private static func formatLayers(_ fileID: AudioFileID) -> [AudioStreamBasicDescription] {
        var size = UInt32(0)
        var writable: UInt32 = 0
        guard AudioFileGetPropertyInfo(fileID, kAudioFilePropertyFormatList, &size, &writable) == noErr,
              size >= UInt32(MemoryLayout<AudioFormatListItem>.size)
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioFormatListItem>.size
        var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: count)
        var readSize = size
        guard AudioFileGetProperty(fileID, kAudioFilePropertyFormatList, &readSize, &items) == noErr
        else { return [] }

        return items.map(\.mASBD).filter { $0.mFormatID != 0 }
    }

    /// ALAC reports 0 in `mBitsPerChannel` and puts the source depth in the
    /// format flags instead, so it needs unpacking separately from PCM.
    private static func bitDepth(of asbd: AudioStreamBasicDescription) -> Int {
        guard asbd.mFormatID == kAudioFormatAppleLossless else {
            return Int(asbd.mBitsPerChannel)
        }
        return switch asbd.mFormatFlags {
        case kAppleLosslessFormatFlag_16BitSourceData: 16
        case kAppleLosslessFormatFlag_20BitSourceData: 20
        case kAppleLosslessFormatFlag_24BitSourceData: 24
        case kAppleLosslessFormatFlag_32BitSourceData: 32
        default: 0
        }
    }
}

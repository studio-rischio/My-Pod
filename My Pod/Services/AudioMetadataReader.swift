import AVFoundation
import CoreMedia
import Foundation

/// Audio properties read from a file via AVAsset, used to populate the iPod's
/// track metadata (`tracklen`, `bitrate`, `samplerate`, `filetype`).
struct AudioFileProperties: Sendable, Equatable {
    var durationMS: Int      // ms
    var bitrate: Int         // kbps
    var sampleRate: Int      // Hz
    var filetypeString: String?
}

/// Stateless helper. AVAsset reads cheaply — just the format atoms — so this is
/// fast enough to run synchronously per-track during a sync.
enum AudioMetadataReader {
    static func read(_ url: URL) async -> AudioFileProperties {
        let asset = AVURLAsset(url: url)

        let duration = (try? await asset.load(.duration)) ?? .zero
        let durationMS = Int((duration.seconds.isFinite ? duration.seconds : 0) * 1000.0)

        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return AudioFileProperties(
                durationMS: durationMS,
                bitrate: 0,
                sampleRate: 0,
                filetypeString: filetypeFromExtension(url)
            )
        }

        let dataRate = (try? await track.load(.estimatedDataRate)) ?? 0
        let bitrate = max(0, Int(dataRate / 1000))   // bits/s → kbps

        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let asbd = descriptions
            .compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            .first
        let sampleRate = Int(asbd?.mSampleRate ?? 0)

        let filetype = filetypeFromCodec(asbd?.mFormatID) ?? filetypeFromExtension(url)

        return AudioFileProperties(
            durationMS: durationMS,
            bitrate: bitrate,
            sampleRate: sampleRate,
            filetypeString: filetype
        )
    }

    private static func filetypeFromCodec(_ codec: AudioFormatID?) -> String? {
        guard let codec else { return nil }
        switch codec {
        case kAudioFormatAppleLossless: return "Apple Lossless audio file"
        case kAudioFormatMPEG4AAC,
             kAudioFormatMPEG4AAC_HE,
             kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD,
             kAudioFormatMPEG4AAC_ELD_SBR,
             kAudioFormatMPEG4AAC_ELD_V2,
             kAudioFormatMPEG4AAC_Spatial:
            return "AAC audio file"
        case kAudioFormatMPEGLayer3, kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer1:
            return "MPEG audio file"
        case kAudioFormatLinearPCM:
            return "WAV audio file"
        default:
            return nil
        }
    }

    private static func filetypeFromExtension(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp3": "MPEG audio file"
        case "m4a", "m4b", "m4p", "aac": "AAC audio file"
        case "wav": "WAV audio file"
        case "aiff", "aif": "AIFF audio file"
        default: nil
        }
    }
}

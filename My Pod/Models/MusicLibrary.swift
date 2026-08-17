import AudioToolbox
import Foundation

/// Audio file extensions playable directly on classic iPods.
/// Mirrors `audio_extensions[]` in ipod-api.c. `nonisolated` so the library
/// scanner (running detached) can call these helpers without main-actor hops.
nonisolated enum AudioFormat {
    static let iPodNative: Set<String> = [
        "mp3", "m4a", "m4b", "m4p", "aac", "wav", "aiff", "aif"
    ]

    /// Files we know how to transcode to AAC via afconvert.
    static let convertible: Set<String> = [
        "flac", "ogg", "opus", "wma", "ape", "alac"
    ]

    static func canSync(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return iPodNative.contains(e) || convertible.contains(e)
    }

    static func needsConversion(_ ext: String) -> Bool {
        !iPodNative.contains(ext.lowercased())
    }

    // MARK: - In-container compatibility
    //
    // A native extension is necessary but not sufficient. `.m4a` covers both
    // AAC-LC 256k (fine) and 24-bit/96 kHz ALAC (skips), and the same hardware
    // limits that made `ConversionService` force `aac@44100` apply to files
    // that arrive already encoded. These rules re-encode a natively-wrapped
    // file when its actual contents are out of spec.

    /// The rate every click-wheel iPod is known to handle, and what an unknown
    /// or untrusted case falls back to.
    ///
    /// Not the rate actually applied: a user can raise the ceiling to 48 kHz in
    /// Settings ▸ Conversion, so the rules below take a `ConversionCeiling` and
    /// read `ceiling.maxSampleRate`.
    static let baseSampleRate = 44_100

    /// Lossless source extensions. Determines the *target* codec under a
    /// lossless ceiling: only these follow it, because re-encoding lossy
    /// material to ALAC inflates it without recovering anything. `m4a` is
    /// absent deliberately — it covers both AAC and ALAC, so it needs the probe
    /// rather than the extension.
    static let losslessExtensions: Set<String> = [
        "flac", "ape", "alac", "wav", "aiff", "aif"
    ]

    /// Whether the source is lossless, by extension and then by contents.
    static func isLossless(_ ext: String, probe: AudioProbe.Format?) -> Bool {
        if let probe { return losslessFormats.contains(probe.formatID) }
        return losslessExtensions.contains(ext.lowercased())
    }

    /// Lossless formats above 16-bit. Click-wheel firmware is a 16-bit
    /// pipeline, so 24-bit ALAC and 24-bit PCM belong here even at 44.1 kHz.
    static let losslessFormats: Set<AudioFormatID> = [
        kAudioFormatAppleLossless, kAudioFormatLinearPCM,
    ]

    /// AAC profiles beyond plain LC. Click-wheel decoders predate SBR/PS, so
    /// an HE-AAC file plays its half-rate core and loses the top octave —
    /// audible as a muffled track rather than an outright failure. Matched
    /// against `AudioProbe.Format.layers`, since the file's data format
    /// advertises only the plain-AAC core.
    static let unplayableAACProfiles: Set<AudioFormatID> = [
        kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
        kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD,
        kAudioFormatMPEG4AAC_ELD_SBR, kAudioFormatMPEG4AAC_ELD_V2,
        kAudioFormatMPEG4AAC_Spatial,
    ]

    /// Extensions worth opening to check. `mp3` is excluded deliberately: MPEG
    /// Layer III tops out at 48 kHz and click-wheel firmware handles the whole
    /// MP3 range, so probing them would mean an open() per file to find
    /// nothing — the dominant cost in a large library.
    static let probeable: Set<String> = [
        "m4a", "m4b", "m4p", "aac", "wav", "aiff", "aif"
    ]

    static func shouldProbe(_ ext: String) -> Bool {
        probeable.contains(ext.lowercased())
    }

    /// Whether a natively-wrapped file can be left exactly as it is.
    ///
    /// Only ever asks whether the file is *above* the ceiling. Something below
    /// it — a 128 kbps MP3, a 32 kHz AAC — passes, because the iPod plays it
    /// and re-encoding upward would cost quality to gain nothing.
    static func isIPodPlayable(_ format: AudioProbe.Format, ceiling: ConversionCeiling) -> Bool {
        // 0 means CoreAudio wouldn't say; don't re-encode on a guess.
        if format.sampleRate > ceiling.maxSampleRate { return false }
        // HE-AAC is never passed through, at any ceiling. It isn't a rate or
        // depth question — click-wheel decoders predate SBR and play only the
        // half-rate core, so the file comes out audibly wrong rather than
        // merely over-spec, and no amount of user opt-in changes that.
        if !format.layers.isDisjoint(with: unplayableAACProfiles) { return false }
        if losslessFormats.contains(format.formatID), format.bitDepth > ceiling.maxBitDepth {
            return false
        }
        return true
    }

    /// Extension check first, then contents. A nil probe (unreadable, DRM'd,
    /// or an extension we don't inspect) leaves the extension's verdict alone.
    static func needsConversion(_ ext: String, probe: AudioProbe.Format?, ceiling: ConversionCeiling) -> Bool {
        if needsConversion(ext) { return true }
        guard let probe else { return false }
        return !isIPodPlayable(probe, ceiling: ceiling)
    }
}

// `nonisolated` on these value types overrides the project-wide
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default. Library scans run on
// detached background tasks, conversion happens off the main actor — these
// types must be readable/constructible from any context.

nonisolated struct LibraryTrack: Sendable, Identifiable, Hashable {
    let id: URL                  // file URL is the stable identity
    var url: URL { id }
    let artist: String
    let album: String
    let trackNumber: Int         // 0 if not parseable
    let title: String            // parsed from filename
    let fileExtension: String
    let sizeBytes: UInt64
    let needsConversion: Bool
    /// Playing time in milliseconds, or 0 when unknown. Only populated for
    /// tracks that need conversion, and only where it's cheap to read from the
    /// file header — FLAC's STREAMINFO block, or `AudioProbe` for a natively
    /// wrapped file whose contents turned out to be out of spec. It exists so
    /// `ConversionService.estimatedIPodBytes` can size the AAC output the
    /// track will actually occupy on the device rather than its source size.
    let durationMS: Int
    /// Source sample rate in Hz, or 0 when unknown. Populated on the same terms
    /// as `durationMS` — only for tracks we'll convert, only where the header
    /// gives it up cheaply. `ConversionCeiling.encodeRate(sourceRate:)` uses it
    /// to avoid resampling a 44.1 kHz source up to the ceiling, which would cost
    /// size and add intersample overshoot for nothing.
    let sampleRate: Int
    /// Source bit depth, or 0 when unknown. Same terms as `sampleRate`. Used
    /// only to size lossless output, where the delivered bytes scale with depth
    /// and rate rather than with a bitrate.
    let bitDepth: Int
    /// Whether the source is lossless. Decides the *target* codec under a
    /// lossless ceiling: lossy material always becomes AAC, since encoding it
    /// to ALAC would inflate it several-fold and recover nothing.
    let isLossless: Bool

    var displayName: String {
        trackNumber > 0 ? String(format: "%02d. %@", trackNumber, title as NSString) : title
    }
}

nonisolated struct LibraryAlbum: Sendable, Identifiable, Hashable {
    var id: String { artist + "/" + name }   // composite, scoped to artist
    let artist: String
    let name: String
    let directory: URL
    /// Creation date of the album folder, or `.distantPast` if unreadable.
    /// Read by the scanner for anything that wants to order by recency.
    let createdAt: Date
    var tracks: [LibraryTrack]

    var sizeBytes: UInt64 { tracks.reduce(0) { $0 &+ $1.sizeBytes } }
    var trackCount: Int { tracks.count }
    var anyNeedsConversion: Bool { tracks.contains(where: \.needsConversion) }
}

nonisolated struct LibraryArtist: Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    var albums: [LibraryAlbum]

    var trackCount: Int { albums.reduce(0) { $0 + $1.trackCount } }
    var sizeBytes: UInt64 { albums.reduce(0) { $0 &+ $1.sizeBytes } }
}

nonisolated struct MusicLibrary: Sendable {
    let root: URL
    var artists: [LibraryArtist]
    var totalTracks: Int
    var scannedAt: Date

    static let empty = MusicLibrary(root: URL(fileURLWithPath: "/"), artists: [], totalTracks: 0, scannedAt: .distantPast)
}

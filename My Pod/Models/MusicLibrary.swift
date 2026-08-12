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

    /// Above this, playback skips on click-wheel hardware — the same finding
    /// that pins the encoder to `aac@44100`. Raising it to 48_000 would spare
    /// 48 kHz files a lossy-to-lossy re-encode at the cost of trusting that
    /// firmware handles them; 44_100 keeps one rule for encoded and decoded
    /// material alike.
    static let maxSampleRate = 44_100

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

    static func isIPodPlayable(_ format: AudioProbe.Format) -> Bool {
        // 0 means CoreAudio wouldn't say; don't re-encode on a guess.
        if format.sampleRate > maxSampleRate { return false }
        if !format.layers.isDisjoint(with: unplayableAACProfiles) { return false }
        if losslessFormats.contains(format.formatID), format.bitDepth > 16 { return false }
        return true
    }

    /// Extension check first, then contents. A nil probe (unreadable, DRM'd,
    /// or an extension we don't inspect) leaves the extension's verdict alone.
    static func needsConversion(_ ext: String, probe: AudioProbe.Format?) -> Bool {
        if needsConversion(ext) { return true }
        guard let probe else { return false }
        return !isIPodPlayable(probe)
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

    var displayName: String {
        trackNumber > 0 ? String(format: "%02d. %@", trackNumber, title as NSString) : title
    }
}

nonisolated struct LibraryAlbum: Sendable, Identifiable, Hashable {
    var id: String { artist + "/" + name }   // composite, scoped to artist
    let artist: String
    let name: String
    let directory: URL
    /// Creation date of the album folder. Drives "newest first" ordering when
    /// auto-selecting new music, so recent additions win the space on a device
    /// that can't hold the whole library. `.distantPast` if unreadable.
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

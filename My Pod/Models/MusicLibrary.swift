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

    /// Everything about a source file that any ceiling could care about,
    /// gathered once at scan time.
    ///
    /// Ceiling-independent on purpose — see `SourceFormat`. FLAC and friends
    /// have no CoreAudio probe, so the scanner fills in rate/depth/duration from
    /// the container header afterwards.
    static func sourceFormat(ext: String, probe: AudioProbe.Format?) -> SourceFormat {
        SourceFormat(
            alwaysConverts: needsConversion(ext),
            sampleRate: probe?.sampleRate ?? 0,
            bitDepth: probe?.bitDepth ?? 0,
            isLossless: isLossless(ext, probe: probe),
            hasUnsupportedAACProfile: probe.map {
                !$0.layers.isDisjoint(with: unplayableAACProfiles)
            } ?? false,
            durationMS: probe?.durationMS ?? 0
        )
    }
}

/// What a source file actually is, independent of what we intend to do with it.
///
/// This exists so `needsConversion` can be answered *at the point of use* rather
/// than frozen into the scan. Two iPods can be attached to the same library at
/// different quality ceilings, and the same file is over-spec for one and fine
/// for the other — so the scan records facts and each caller applies its own
/// ceiling to them.
///
/// It costs nothing extra to gather. The ceilings form a ladder where each rung
/// is strictly looser than the one below, so anything in spec at the strictest
/// rung is in spec at every rung: the scanner probes exactly the same files it
/// always did, and only the *storing* of the result became unconditional.
nonisolated struct SourceFormat: Sendable, Hashable {
    /// The extension alone forces conversion (FLAC, OGG, Opus, WMA, APE). No
    /// ceiling can let these through, so nothing else here is consulted.
    var alwaysConverts: Bool = false
    /// Effective rate in Hz — the max across codec layers, so an HE-AAC file
    /// reports what it plays at rather than its half-rate core. 0 when unknown.
    var sampleRate: Int = 0
    /// Bits per channel, 0 when unknown. Only meaningful with `isLossless`:
    /// a lossy file's depth says nothing about what the iPod has to decode.
    var bitDepth: Int = 0
    /// Whether the source is lossless. Decides the *target* codec under a
    /// lossless ceiling — lossy material always becomes AAC, since encoding it
    /// to ALAC would inflate it several-fold and recover nothing.
    var isLossless: Bool = false
    /// HE-AAC, ELD, spatial. Never passed through at any ceiling: click-wheel
    /// decoders predate SBR, so the file plays audibly wrong rather than merely
    /// over-spec, and no amount of user opt-in changes that.
    var hasUnsupportedAACProfile: Bool = false
    /// Playing time in ms, 0 when unknown. Used to size converted output.
    var durationMS: Int = 0

    /// Whether this file has to be re-encoded to reach an iPod set to `ceiling`.
    ///
    /// Only ever asks whether the file is *above* the ceiling. Something below
    /// it — a 128 kbps MP3, a 32 kHz AAC — passes untouched, because the iPod
    /// plays it and re-encoding upward would cost quality to gain nothing.
    func needsConversion(under ceiling: ConversionCeiling) -> Bool {
        if alwaysConverts { return true }
        if hasUnsupportedAACProfile { return true }
        // 0 means the header wouldn't say; don't re-encode on a guess.
        if sampleRate > ceiling.maxSampleRate { return true }
        if isLossless, bitDepth > ceiling.maxBitDepth { return true }
        return false
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
    /// What the file actually is. Deliberately not "does it need converting" —
    /// that answer depends on which iPod is being filled, so it's computed by
    /// `needsConversion(under:)` at the point of use.
    let format: SourceFormat

    func needsConversion(under ceiling: ConversionCeiling) -> Bool {
        format.needsConversion(under: ceiling)
    }

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

    func anyNeedsConversion(under ceiling: ConversionCeiling) -> Bool {
        tracks.contains { $0.needsConversion(under: ceiling) }
    }
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

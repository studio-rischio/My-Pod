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
    /// formats that need conversion, and only where it's cheap to read from
    /// the file header (currently FLAC's STREAMINFO block) — it exists so
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

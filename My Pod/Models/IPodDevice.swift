import Foundation

enum IPodError: LocalizedError {
    case openFailed(String)
    case saveFailed(String)
    case syncFailed(String)
    case notOpen

    var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "Couldn't open iPod: \(m)"
        case .saveFailed(let m): return "Couldn't save iPod database: \(m)"
        case .syncFailed(let m): return "Sync failed: \(m)"
        case .notOpen: return "iPod is not open."
        }
    }
}

struct SyncStats: Sendable, Equatable {
    var added: Int
    var skipped: Int
    var removed: Int
    var failed: Int
    var totalOnDevice: Int

    static let zero = SyncStats(added: 0, skipped: 0, removed: 0, failed: 0, totalOnDevice: 0)
}

actor IPodDevice {
    let mountpoint: URL
    private nonisolated(unsafe) var db: OpaquePointer?

    init(mountpoint: URL) {
        self.mountpoint = mountpoint
    }

    func open() throws {
        guard db == nil else { return }
        var errorPtr: UnsafeMutablePointer<CChar>? = nil
        let handle: OpaquePointer? = mountpoint.path.withCString { mountCStr in
            ipod_open(mountCStr, &errorPtr)
        }
        guard let handle else {
            let msg = errorPtr.flatMap { String(cString: $0) } ?? "Unknown error"
            ipod_free_string(errorPtr)
            throw IPodError.openFailed(msg)
        }
        ipod_free_string(errorPtr)
        self.db = handle
    }

    func close() {
        guard let db else { return }
        ipod_close(db)
        self.db = nil
    }

    func save() throws {
        guard let db else { throw IPodError.notOpen }
        let result = ipod_save(db)
        if result.success == 0 {
            let msg = result.error.flatMap { String(cString: $0) } ?? "Unknown error"
            ipod_free_string(result.error)
            throw IPodError.saveFailed(msg)
        }
        ipod_free_string(result.error)
    }

    func deviceInfo() -> DeviceInfo? {
        guard let db else { return nil }
        guard let raw = ipod_get_device_info(db) else { return nil }
        defer { ipod_free_device_info(raw) }
        return DeviceInfo(raw, mountpoint: mountpoint)
    }

    func trackCount() -> Int {
        guard let db else { return 0 }
        return Int(ipod_get_track_count(db))
    }

    /// Sum of all track sizes in bytes — used to draw the storage bar's "Music" segment.
    func totalMusicBytes() -> UInt64 {
        guard let db else { return 0 }
        let count = ipod_get_track_count(db)
        var total: UInt64 = 0
        for i in 0..<count {
            guard let raw = ipod_get_track_at_index(db, i) else { continue }
            total &+= UInt64(raw.pointee.size_bytes)
            ipod_free_track_info(raw)
        }
        return total
    }

    func tracks() -> [TrackInfo] {
        guard let db else { return [] }
        let count = ipod_get_track_count(db)
        var out: [TrackInfo] = []
        out.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let raw = ipod_get_track_at_index(db, i) else { continue }
            out.append(TrackInfo(raw))
            ipod_free_track_info(raw)
        }
        return out
    }

    /// Copy a file onto the iPod and add it to the master playlist.
    /// Audio metadata (duration / bitrate / sample rate / filetype) is essential
    /// — the iPod will skip tracks whose `tracklen` is zero.
    ///
    /// `artworkPath` (when non-nil) is attached via `itdb_track_set_thumbnails`
    /// before the track is registered with the database — same order as
    /// ipod-sync.c's working CLI flow.
    func addTrack(
        filepath: URL,
        title: String,
        artist: String,
        album: String,
        trackNumber: Int,
        durationMS: Int = 0,
        bitrate: Int = 0,
        sampleRate: Int = 0,
        filetype: String? = nil,
        genre: String? = nil,
        year: Int = 0,
        discNumber: Int = 0,
        artworkPath: String? = nil
    ) throws {
        guard let db else { throw IPodError.notOpen }
        // macOS gives filesystem-derived strings in NFD (decomposed: e.g. "u" +
        // combining diaeresis). iPod firmware expects NFC (precomposed: "ü") —
        // it has no glyphs for combining marks and renders NFD as the base
        // letter followed by a raw mark glyph ("Gu¨n"). Normalize at the C
        // boundary so anything reaching libgpod is iPod-renderable. The
        // filepath stays in its original form because the filesystem itself
        // expects NFD on HFS+/APFS.
        let nfcTitle  = title.precomposedStringWithCanonicalMapping
        let nfcArtist = artist.precomposedStringWithCanonicalMapping
        let nfcAlbum  = album.precomposedStringWithCanonicalMapping
        let nfcGenre  = genre?.precomposedStringWithCanonicalMapping
        let nfcFiletype = filetype?.precomposedStringWithCanonicalMapping

        let result: IPodResult = filepath.path.withCString { fpath in
            nfcTitle.withCString { t in
                nfcArtist.withCString { a in
                    nfcAlbum.withCString { al in
                        let genreCStr = nfcGenre?.withCString { strdup($0) }
                        let filetypeCStr = nfcFiletype?.withCString { strdup($0) }
                        let artworkCStr = artworkPath?.withCString { strdup($0) }
                        defer {
                            free(genreCStr)
                            free(filetypeCStr)
                            free(artworkCStr)
                        }
                        return ipod_add_track_full(
                            db,
                            fpath,
                            t,
                            a,
                            al,
                            Int32(trackNumber),
                            Int32(discNumber),
                            Int32(durationMS),
                            Int32(bitrate),
                            Int32(sampleRate),
                            Int32(year),
                            genreCStr.map { UnsafePointer($0) },
                            filetypeCStr.map { UnsafePointer($0) },
                            artworkCStr.map { UnsafePointer($0) }
                        )
                    }
                }
            }
        }
        if result.success == 0 {
            let msg = result.error.flatMap { String(cString: $0) } ?? "Unknown error"
            ipod_free_string(result.error)
            throw IPodError.syncFailed(msg)
        }
        ipod_free_string(result.error)
    }

    /// Remove a track from the iPod database (and delete the file from the iPod).
    func removeTrack(trackID: UInt32) throws {
        guard let db else { throw IPodError.notOpen }
        let result = ipod_remove_track(db, trackID)
        if result.success == 0 {
            let msg = result.error.flatMap { String(cString: $0) } ?? "Unknown error"
            ipod_free_string(result.error)
            throw IPodError.syncFailed(msg)
        }
        ipod_free_string(result.error)
    }

    /// Every user-created playlist currently on the iPod, master playlist
    /// excluded (it mirrors the whole library, so it's never a user playlist).
    func userPlaylists() -> [DevicePlaylist] {
        guard let db else { return [] }
        let count = ipod_get_playlist_count(db)
        var out: [DevicePlaylist] = []
        out.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let raw = ipod_get_playlist_at_index(db, i) else { continue }
            defer { ipod_free_playlist_info(raw) }
            guard raw.pointee.is_master == 0 else { continue }
            out.append(DevicePlaylist(raw))
        }
        return out
    }

    /// Create a new (non-smart) playlist on the iPod and return its ID.
    func createPlaylist(name: String) throws -> UInt64 {
        guard let db else { throw IPodError.notOpen }
        // NFC for the same reason as addTrack: playlist filenames come off
        // the filesystem in NFD on macOS and the iPod can't render combining
        // marks correctly.
        let nfcName = name.precomposedStringWithCanonicalMapping
        let id = nfcName.withCString { ipod_create_playlist(db, $0) }
        guard id != 0 else {
            throw IPodError.syncFailed("Couldn't create playlist \"\(name)\"")
        }
        return id
    }

    /// Append a track (already on the iPod) to a playlist.
    /// Add a track to a playlist by its position in the device's track list.
    ///
    /// Not by ID, deliberately. libgpod assigns track IDs during `itdb_write`,
    /// not during `itdb_track_add`, so anything added since the last save still
    /// reports id 0 — and `itdb_track_by_id(0)` returns whichever track is first
    /// with that value. Every entry then lands on the same track, which is a
    /// playlist that looks written and is silently wrong.
    ///
    /// The index comes from `tracks()`, which walks the same list. Nothing may
    /// add or remove tracks in between.
    func addTrackToPlaylist(playlistID: UInt64, trackIndex: Int) throws {
        guard let db else { throw IPodError.notOpen }
        let result = ipod_playlist_add_track_at_index(db, playlistID, Int32(trackIndex))
        if result.success == 0 {
            let msg = result.error.flatMap { String(cString: $0) } ?? "Unknown error"
            ipod_free_string(result.error)
            throw IPodError.syncFailed(msg)
        }
        ipod_free_string(result.error)
    }

    /// Wipe every user-created playlist (everything except the master playlist).
    /// Tracks themselves are untouched.
    @discardableResult
    func clearUserPlaylists() -> Int {
        guard let db else { return 0 }
        return Int(ipod_clear_user_playlists(db))
    }

    /// Attach a thumbnail image to a track that's already on the iPod.
    /// libgpod renders the actual thumbnails lazily on the next `save()`.
    func setTrackArtwork(trackID: UInt32, imagePath: String) throws {
        guard let db else { throw IPodError.notOpen }
        let result = imagePath.withCString { cstr in
            ipod_set_track_artwork(db, trackID, cstr)
        }
        if result.success == 0 {
            let msg = result.error.flatMap { String(cString: $0) } ?? "Unknown error"
            ipod_free_string(result.error)
            throw IPodError.saveFailed(msg)
        }
        ipod_free_string(result.error)
    }

    /// Mirror `folder` to the iPod via `ipod_sync_folder`. The folder must be
    /// Plex-structured (Root/Artist/Album/Track) and may include a top-level
    /// `Playlists/` directory of M3U files.
    func syncFolder(_ folder: URL, removeMissing: Bool) throws -> SyncStats {
        guard let db else { throw IPodError.notOpen }
        var errorPtr: UnsafeMutablePointer<CChar>? = nil
        let cStats = folder.path.withCString { cstr in
            ipod_sync_folder(db, cstr, removeMissing ? 1 : 0, &errorPtr)
        }
        let errorMsg = errorPtr.flatMap { String(cString: $0) }
        ipod_free_string(errorPtr)

        let stats = SyncStats(
            added: Int(cStats.added),
            skipped: Int(cStats.skipped),
            removed: Int(cStats.removed),
            failed: Int(cStats.failed),
            totalOnDevice: Int(cStats.total_on_device)
        )
        if let errorMsg, !errorMsg.isEmpty,
           stats.added == 0 && stats.removed == 0 && stats.skipped == 0 {
            throw IPodError.syncFailed(errorMsg)
        }
        return stats
    }

    deinit {
        if let db {
            ipod_close(db)
        }
    }
}

/// Static helpers for iPod-wide reset operations. These run without an open
/// `IPodDB` — the device must be closed before calling them, because they
/// rewrite the on-disk database files directly. `nonisolated` so the
/// controller can dispatch them off main actor via `Task.detached`.
nonisolated enum IPodReset {
    /// Nuke everything iPod-managed: Music/, Artwork/, and the iTunesDB.
    /// Slow — the C side walks both directory trees.
    static func fullReset(at mountpoint: URL) throws {
        let result = mountpoint.path.withCString { ipod_full_reset($0) }
        if result.success == 0 {
            let msg = result.error.flatMap { String(cString: $0) } ?? "Full reset failed"
            ipod_free_string(result.error)
            throw IPodError.syncFailed(msg)
        }
        ipod_free_string(result.error)
    }
}

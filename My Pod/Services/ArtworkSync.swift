import Foundation

/// One album whose cover art on disk is newer than what a device holds, or has
/// been pushed by hand.
nonisolated struct ArtworkUpdate: Sendable, Equatable, Identifiable {
    /// `LibraryAlbum.id` — `<artist>/<name>`.
    let albumID: String
    let artist: String
    let album: String
    /// The image libgpod renders thumbnails from. It must still exist when
    /// `save()` runs — `itdb_write` renders lazily — which is free here, unlike
    /// the add path: this file lives in the user's album folder, not a scratch
    /// directory.
    let coverURL: URL
    /// iPod track IDs to attach it to. Every track of the album that's on the
    /// device, since artwork on the iPod is per-track and not per-album.
    let trackIDs: [UInt32]

    var id: String { albumID }
}

/// Decides which albums already on an iPod need their cover art refreshed.
///
/// The problem it exists for: `SyncEngine.plan` treats a track already on the
/// device as `unchanged` and never revisits it, and artwork is only attached
/// inside the add phase. So art acquired *after* an album was synced would never
/// reach the device — the album stays blank, with no error and no way for the
/// user to tell why.
///
/// Two triggers, because neither covers the other's case:
///
/// - **The cover file is newer than the device's baseline.** Catches "I just set
///   the artwork". The timestamp lives on the file, so art replaced in Finder
///   counts exactly like art set through the app, and there's no queue to fall
///   out of step with the filesystem.
/// - **The album was queued explicitly.** Catches "the file on disk is already
///   right, the *iPod* is wrong" — nothing changed, so no date comparison would
///   ever fire.
@MainActor
enum ArtworkSync {
    private static var defaults: UserDefaults { .standard }

    private static func baselineKey(_ profile: DeviceProfile) -> String {
        profile.storageKey("artworkSyncedAt")
    }

    private static func queueKey(_ profile: DeviceProfile) -> String {
        profile.storageKey("artworkQueue")
    }

    // MARK: - Baseline

    /// When this device last received artwork, or nil if it has no baseline.
    static func baseline(for profile: DeviceProfile) -> Date? {
        defaults.object(forKey: baselineKey(profile)) as? Date
    }

    /// Record a baseline for a device that has none, without moving one that
    /// already exists.
    ///
    /// Called on every connect, which makes it both the migration for profiles
    /// written before this feature and the starting point for newly-seen iPods.
    /// It has to be *now* rather than `.distantPast`: an iPod already holds
    /// whatever art it holds, and treating every album as changed would push
    /// artwork for the entire library on the first sync after upgrading — slow,
    /// alarming, and impossible to explain.
    static func establishBaseline(for profile: DeviceProfile) {
        guard baseline(for: profile) == nil else { return }
        defaults.set(Date(), forKey: baselineKey(profile))
        Log.artwork.info("artwork baseline set for \"\(profile.displayName)\"")
    }

    /// Send every album's cover again on the next sync.
    ///
    /// The one caller is a device that has just gone from unable to receive
    /// artwork to able — the user identified it. `establishBaseline`'s reasoning
    /// inverts there: an iPod libgpod couldn't name has been restored by
    /// something modern and holds no art at all, and every track already on it
    /// was added while libgpod was silently dropping covers. Left alone, the
    /// sync diff calls those tracks `unchanged` forever and the artwork never
    /// arrives, so identifying the iPod would fix the *next* album and nothing
    /// the user already synced.
    static func resendEverything(to profile: DeviceProfile) {
        defaults.set(Date.distantPast, forKey: baselineKey(profile))
        Log.artwork.info("\"\(profile.displayName)\" can take artwork now — every album's cover will be sent on the next sync")
    }

    static func markSynced(_ profile: DeviceProfile, at date: Date = Date()) {
        defaults.set(date, forKey: baselineKey(profile))
        Log.artwork.debug("artwork baseline for \"\(profile.displayName)\" moved to \(date)")
    }

    // MARK: - Explicit queue

    static func queued(for profile: DeviceProfile) -> Set<String> {
        Set(defaults.stringArray(forKey: queueKey(profile)) ?? [])
    }

    static func enqueue(_ albumID: String, for profile: DeviceProfile) {
        var set = queued(for: profile)
        guard set.insert(albumID).inserted else { return }
        defaults.set(Array(set), forKey: queueKey(profile))
        Log.artwork.info("queued artwork for \"\(albumID)\" on \"\(profile.displayName)\"")
    }

    /// Queue an album's art for the next sync, and report which iPods were told.
    ///
    /// With a device connected, that device. With nothing connected the active
    /// profile is the *default* one, which never syncs — so the instruction goes
    /// to every iPod the app knows, which is what "fix this on my iPod" means
    /// when the iPod isn't plugged in.
    @discardableResult
    static func enqueueForNextSync(albumID: String, store: DeviceProfileStore) -> [String] {
        let targets = store.active.isDefault ? store.devices : [store.active]
        if targets.isEmpty {
            // Not an error: this is a first run, or the user has never plugged
            // an iPod in. The file on disk is still newer than any baseline a
            // future device will be given, so it isn't lost.
            Log.artwork.info("artwork for \"\(albumID)\" not queued — no iPod has been seen yet")
        }
        for profile in targets { enqueue(albumID, for: profile) }
        return targets.map(\.displayName)
    }

    static func clearQueue(for profile: DeviceProfile) {
        let pending = queued(for: profile).count
        defaults.removeObject(forKey: queueKey(profile))
        if pending > 0 {
            Log.artwork.info("cleared \(pending) queued artwork request(s) for \"\(profile.displayName)\"")
        }
    }

    /// Drop both keys when a device is forgotten, so they don't outlive it.
    static func forget(_ profile: DeviceProfile) {
        defaults.removeObject(forKey: baselineKey(profile))
        defaults.removeObject(forKey: queueKey(profile))
    }

    // MARK: - Planning

    /// Albums the device already holds whose art needs pushing.
    ///
    /// A nil `changedSince` means no baseline was recorded, and the answer is
    /// "nothing" rather than "everything" — see `establishBaseline`. Explicitly
    /// queued albums still go, since those are a direct instruction.
    nonisolated static func updates(
        library: MusicLibrary,
        deviceTracks: [TrackInfo],
        queued: Set<String>,
        changedSince: Date?
    ) -> [ArtworkUpdate] {
        guard !deviceTracks.isEmpty else { return [] }

        // Artwork is per-track on the iPod, so one album maps to as many IDs as
        // it has tracks on the device. Duplicate keys accumulate rather than
        // overwrite — two files that normalize to the same key are two rows in
        // the database, and leaving one of them blank looks like a bug.
        var idsByKey: [TrackKey: [UInt32]] = [:]
        for track in deviceTracks {
            idsByKey[TrackKey(ipod: track), default: []].append(track.id)
        }

        var out: [ArtworkUpdate] = []
        for artist in library.artists {
            for album in artist.albums {
                // Cheapest test first, deliberately. An album the device
                // doesn't hold can't have its artwork refreshed, and this is
                // a dictionary lookup where the two tests below are a directory
                // enumeration and a stat. On a library where only part is
                // synced, most albums exit here and never touch the disk.
                let trackIDs = album.tracks.flatMap { idsByKey[TrackKey(library: $0)] ?? [] }
                guard !trackIDs.isEmpty else { continue }

                guard let cover = ArtworkLocator.imageInDirectory(album.directory) else {
                    if queued.contains(album.id) {
                        // Asked for, but there is no file to send. Only reachable
                        // if the image was deleted between queueing and syncing —
                        // the button that queues is gated on one existing.
                        Log.artwork.warning(
                            "queued artwork for \(album.artist) — \(album.name) has no image file in the folder; skipping"
                        )
                    }
                    continue
                }
                if !queued.contains(album.id) {
                    guard let since = changedSince,
                          let modified = try? cover.resourceValues(
                              forKeys: [.contentModificationDateKey]
                          ).contentModificationDate,
                          modified > since
                    else { continue }
                }
                out.append(ArtworkUpdate(
                    albumID: album.id,
                    artist: album.artist,
                    album: album.name,
                    coverURL: cover,
                    trackIDs: trackIDs
                ))
            }
        }
        return out.sorted {
            $0.artist == $1.artist
                ? $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending
                : $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
        }
    }

    /// Attach `update`'s cover to every one of its tracks. Returns true if any
    /// track took it — the caller still has to `save()`.
    ///
    /// Failures are logged and swallowed per track: a single unreadable image or
    /// a track that vanished between plan and execute is not a reason to abandon
    /// a sync that has already mutated the database.
    static func apply(_ update: ArtworkUpdate, to device: IPodDevice) async -> Bool {
        var applied = false
        Log.artwork.debug(
            "applying \(update.coverURL.lastPathComponent) to \(update.trackIDs.count) track(s) of \(update.artist) — \(update.album)"
        )
        for trackID in update.trackIDs {
            do {
                try await device.setTrackArtwork(trackID: trackID, imagePath: update.coverURL.path)
                applied = true
            } catch {
                Log.artwork.warning(
                    "artwork failed for \(update.artist) — \(update.album) (track \(trackID)): \(error.localizedDescription)"
                )
            }
        }
        return applied
    }
}

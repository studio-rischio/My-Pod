import Foundation
import Observation

@MainActor
@Observable
final class SyncEngine {
    private(set) var state: SyncState = .idle
    let conversionService = ConversionService()
    private var cancelRequested = false

    /// Phase weighting for the run in flight, derived from its plan. Only the
    /// Dock bar uses it — the in-app sheet shows real per-phase counts.
    private(set) var phaseWeights: SyncPhaseWeights?

    /// Progress across the whole sync as a single 0–1 value, or nil when no
    /// sync is running. Feeds the Dock tile.
    var overallFraction: Double? {
        guard case .running(let progress) = state else { return nil }
        return phaseWeights?.fraction(at: progress)
    }

    /// Scratch dir for artwork files extracted from embedded sources.
    /// Lives in Caches so macOS can clean it; we wipe it at the start of each sync.
    private let artworkScratchDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("My Pod/sync-artwork", isDirectory: true)
    }()

    func reset() {
        state = .idle
        cancelRequested = false
        phaseWeights = nil
    }

    /// User-initiated cancel. The engine finishes the current track (so the iPod
    /// isn't left mid-write), then saves whatever progress was made.
    func cancel() {
        Log.sync.warning("cancel requested by user")
        cancelRequested = true
    }

    var isCancelling: Bool {
        guard cancelRequested else { return false }
        if case .running = state { return true }
        return false
    }

    // MARK: - Plan

    func plan(
        libraryRoot: URL,
        library: MusicLibrary,
        selectedPaths: Set<String>,
        playlists: [Playlist],
        device: IPodDevice
    ) async {
        Log.sync.info("plan started: \(selectedPaths.count) selected, \(playlists.count) playlists")
        state = .planning
        cancelRequested = false
        let iPodTracks = await device.tracks()
        let devicePlaylists = await device.userPlaylists()

        if let refusal = Self.refusalReason(library: library, iPodTrackCount: iPodTracks.count) {
            Log.sync.error("refusing to plan: library scanned 0 tracks while the iPod holds \(iPodTracks.count)")
            state = .failed(refusal)
            return
        }

        let plan = Self.computePlan(
            libraryRoot: libraryRoot,
            library: library,
            selectedPaths: selectedPaths,
            playlists: playlists,
            iPodTracks: iPodTracks,
            devicePlaylists: devicePlaylists,
            conversion: conversionService
        )
        Log.sync.info("plan: +\(plan.toAddCount) -\(plan.toRemoveCount), \(plan.unchangedCount) unchanged, \(plan.pendingConversion.count) need convert")
        Log.playlist.info("plan: playlists +\(plan.playlists(.added).count) -\(plan.playlists(.removed).count) ~\(plan.playlists(.modified).count), \(plan.playlists(.unchanged).count) unchanged")
        state = .planned(plan)
    }

    /// Why a sync must not be planned, or nil to proceed.
    ///
    /// `LibraryScanner` fails soft: an unreadable root — an external drive that
    /// isn't mounted, a renamed folder — returns an empty library rather than an
    /// error, and is then indistinguishable from a real one. Because the desired
    /// set is `selected ∩ scanned` (see `computePlan`), an empty scan drops every
    /// track and the plan becomes "remove everything on the device".
    ///
    /// That plan is shown before it runs, so it isn't silent, but it is one
    /// confirmation away from erasing an iPod because a cable was loose. Wiping
    /// is the only mistake here that destroys something the user can't get back
    /// from this app, so it's refused rather than offered.
    ///
    /// Deliberately narrow. Unticking everything in a library that *did* scan
    /// still clears the device — that's an explicit instruction, and it leaves
    /// `totalTracks > 0`. The cost is that a genuinely empty library folder can
    /// no longer be used to empty an iPod, which is a fair trade for the
    /// failure it prevents.
    static func refusalReason(library: MusicLibrary, iPodTrackCount: Int) -> String? {
        guard library.totalTracks == 0, iPodTrackCount > 0 else { return nil }
        return """
            Your music library scanned as empty, but the iPod holds \(iPodTrackCount) \
            track\(iPodTrackCount == 1 ? "" : "s"). Syncing now would remove all of them.

            This usually means the library folder can't be read — an external drive \
            that isn't connected, or a folder that moved or was renamed. Check that \
            \(library.root.path) is available, then scan again.
            """
    }

    static func computePlan(
        libraryRoot: URL,
        library: MusicLibrary,
        selectedPaths: Set<String>,
        playlists: [Playlist],
        iPodTracks: [TrackInfo],
        devicePlaylists: [DevicePlaylist],
        conversion: ConversionService
    ) -> SyncPlan {
        // 1. path → LibraryTrack lookup. Keyed by `.path` to dodge URL
        // canonicalization differences between scan and persistence.
        var byPath: [String: LibraryTrack] = [:]
        byPath.reserveCapacity(library.totalTracks)
        for artist in library.artists {
            for album in artist.albums {
                for t in album.tracks { byPath[t.url.path] = t }
            }
        }

        // 2. Desired set = checkbox-selected only. Playlists are NOT force-
        // included — their entries get pruned to whatever ends up on the iPod
        // during the playlist-write phase. This matches the iTunes "sync only
        // checked songs" model: an unchecked track stays off the iPod even if
        // a playlist references it.
        let desiredPaths: Set<String> = selectedPaths.intersection(byPath.keys)

        // 3. Build planned tracks.
        var planned: [PlannedTrack] = []
        planned.reserveCapacity(desiredPaths.count)
        for path in desiredPaths {
            guard let lib = byPath[path] else { continue }
            let sourceURL = lib.needsConversion ? conversion.iPodPlayableURL(for: lib) : lib.url
            planned.append(PlannedTrack(
                library: lib,
                sourceURL: sourceURL,
                needsConversion: lib.needsConversion
            ))
        }
        // Sort planned by artist/album/track for predictable progress UX.
        planned.sort { lhs, rhs in
            if lhs.library.artist != rhs.library.artist {
                return lhs.library.artist.localizedCaseInsensitiveCompare(rhs.library.artist) == .orderedAscending
            }
            if lhs.library.album != rhs.library.album {
                return lhs.library.album.localizedCaseInsensitiveCompare(rhs.library.album) == .orderedAscending
            }
            return lhs.library.trackNumber < rhs.library.trackNumber
        }

        // 4. Diff against the iPod by (artist, album, title) key.
        let plannedKeys = Set(planned.map { TrackKey(plan: $0) })
        let iPodByKey: [TrackKey: TrackInfo] = Dictionary(
            iPodTracks.map { (TrackKey(ipod: $0), $0) },
            uniquingKeysWith: { a, _ in a }
        )

        let toAdd = planned.filter { !iPodByKey.keys.contains(TrackKey(plan: $0)) }
        let toRemove = iPodTracks.filter { !plannedKeys.contains(TrackKey(ipod: $0)) }
        let unchangedCount = plannedKeys.count - toAdd.count

        // 5. Conversions still needed.
        let pendingConversion = planned
            .filter { $0.needsConversion && !conversion.isCached($0.library) }
            .map(\.library)

        // 6. Sizes.
        let addedBytes: UInt64 = toAdd.reduce(0) { $0 &+ $1.library.sizeBytes }
        let removedBytes: UInt64 = toRemove.reduce(0) { $0 &+ UInt64($1.sizeBytes) }

        // 7. Playlist diff. The post-sync device holds exactly `plannedKeys`,
        // so that's what playlist entries get resolved against.
        let playlistChanges = computePlaylistChanges(
            playlists: playlists,
            devicePlaylists: devicePlaylists,
            iPodTracks: iPodTracks,
            postSyncKeys: plannedKeys
        )

        return SyncPlan(
            toAdd: toAdd,
            toRemove: toRemove,
            unchangedCount: unchangedCount,
            pendingConversion: pendingConversion,
            addedBytes: addedBytes,
            removedBytes: removedBytes,
            playlistCount: playlists.count,
            playlistChanges: playlistChanges
        )
    }

    /// Diff the M3U playlists against the iPod's user playlists.
    ///
    /// Entries are resolved to `TrackKey`s and filtered to `postSyncKeys` —
    /// the playlist-write phase drops entries whose track isn't on the device,
    /// so a playlist "changes" when a track it references is being added or
    /// removed by this same sync, not only when the .m3u itself was edited.
    static func computePlaylistChanges(
        playlists: [Playlist],
        devicePlaylists: [DevicePlaylist],
        iPodTracks: [TrackInfo],
        postSyncKeys: Set<TrackKey>
    ) -> [PlaylistChange] {
        var keysByTrackID: [UInt32: TrackKey] = [:]
        keysByTrackID.reserveCapacity(iPodTracks.count)
        for t in iPodTracks { keysByTrackID[t.id] = TrackKey(ipod: t) }

        var deviceByName: [String: DevicePlaylist] = [:]
        for pl in devicePlaylists {
            deviceByName[Playlist.nameKey(pl.name)] = pl
        }

        var changes: [PlaylistChange] = []
        var seenNames = Set<String>()

        for playlist in playlists {
            let nameKey = playlist.nameKey
            seenNames.insert(nameKey)

            var resolved: [TrackKey] = []
            var unresolved = 0
            for entry in playlist.entries {
                guard let key = playlistEntryKey(entry: entry), postSyncKeys.contains(key) else {
                    unresolved += 1
                    continue
                }
                resolved.append(key)
            }
            let newKeys = Set(resolved)

            guard let existing = deviceByName[nameKey] else {
                changes.append(PlaylistChange(
                    name: playlist.name,
                    kind: .added,
                    entriesAdded: resolved.count,
                    entriesRemoved: 0,
                    finalCount: resolved.count,
                    unresolvedCount: unresolved
                ))
                continue
            }

            let oldKeys = Set(existing.trackIDs.compactMap { keysByTrackID[$0] })
            let gained = newKeys.subtracting(oldKeys).count
            let lost = oldKeys.subtracting(newKeys).count
            changes.append(PlaylistChange(
                name: playlist.name,
                kind: (gained == 0 && lost == 0) ? .unchanged : .modified,
                entriesAdded: gained,
                entriesRemoved: lost,
                finalCount: resolved.count,
                unresolvedCount: unresolved
            ))
        }

        // Anything left on the iPod without an .m3u backing it is going away.
        for pl in devicePlaylists where !seenNames.contains(Playlist.nameKey(pl.name)) {
            changes.append(PlaylistChange(
                name: pl.name,
                kind: .removed,
                entriesAdded: 0,
                entriesRemoved: pl.trackCount,
                finalCount: 0,
                unresolvedCount: 0
            ))
        }

        let order = Dictionary(uniqueKeysWithValues: PlaylistChange.Kind.allCases.enumerated().map { ($1, $0) })
        changes.sort { lhs, rhs in
            let l = order[lhs.kind] ?? 0, r = order[rhs.kind] ?? 0
            if l != r { return l < r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return changes
    }

    // MARK: - Execute

    func execute(
        plan: SyncPlan,
        libraryRoot: URL,
        playlists: [Playlist],
        device: IPodDevice
    ) async {
        Log.sync.info("execute started: +\(plan.toAddCount) -\(plan.toRemoveCount) convert=\(plan.pendingConversion.count)")
        cancelRequested = false
        phaseWeights = SyncPhaseWeights(plan: plan)
        var convertedFailures = 0
        var added = 0, removed = 0, addFailed = 0, removeFailed = 0

        // 1. Convert any pending tracks. Conversion runs to completion (mid-batch
        // cancel isn't supported yet) — but we honour cancel between phases.
        if !plan.pendingConversion.isEmpty {
            Log.sync.info("phase: converting (\(plan.pendingConversion.count) tracks)")
            let convertStart = Date()
            state = .running(SyncProgress(phase: .converting, completed: 0, total: plan.pendingConversion.count, phaseStartedAt: convertStart))
            let results = await conversionService.ensure(tracks: plan.pendingConversion) { [weak self] c, t in
                Task { @MainActor [weak self] in
                    if case .running(var p) = self?.state, p.phase == .converting {
                        p.completed = c
                        p.total = t
                        self?.state = .running(p)
                    }
                }
            }
            for (_, outcome) in results {
                if case .failure = outcome { convertedFailures += 1 }
            }
            Log.sync.info("phase: converting done (\(convertedFailures) failed of \(plan.pendingConversion.count))")
            if convertedFailures == plan.pendingConversion.count, !plan.pendingConversion.isEmpty {
                Log.sync.error("aborting: all \(convertedFailures) conversions failed")
                state = .failed("All \(convertedFailures) conversions failed.")
                return
            }
        }

        if cancelRequested {
            await finishCancelled(device: device, added: added, removed: removed,
                                  failed: addFailed + removeFailed,
                                  convertedFailures: convertedFailures)
            return
        }

        // 2. Remove tracks (per-track, with progress + cancel between each).
        if !plan.toRemove.isEmpty {
            Log.sync.info("phase: removing (\(plan.toRemove.count) tracks)")
            let removeStart = Date()
            state = .running(SyncProgress(phase: .removing, completed: 0, total: plan.toRemove.count, phaseStartedAt: removeStart))
            for (i, track) in plan.toRemove.enumerated() {
                if cancelRequested { break }
                state = .running(SyncProgress(
                    phase: .removing,
                    completed: i,
                    total: plan.toRemove.count,
                    detail: "\(track.artist) — \(track.title)",
                    phaseStartedAt: removeStart
                ))
                do {
                    try await device.removeTrack(trackID: track.id)
                    removed += 1
                } catch {
                    Log.sync.warning("remove failed: \(track.artist) — \(track.title): \(error.localizedDescription)")
                    removeFailed += 1
                }
            }
            state = .running(SyncProgress(phase: .removing, completed: removed + removeFailed, total: plan.toRemove.count, phaseStartedAt: removeStart))
            Log.sync.info("phase: removing done (\(removed) ok, \(removeFailed) failed)")
        }

        if cancelRequested {
            await finishCancelled(device: device, added: added, removed: removed,
                                  failed: addFailed + removeFailed,
                                  convertedFailures: convertedFailures)
            return
        }

        // 3. Add tracks.
        let validToAdd = plan.toAdd.filter {
            FileManager.default.fileExists(atPath: $0.sourceURL.path)
        }
        let missingFromDisk = plan.toAdd.count - validToAdd.count
        addFailed += missingFromDisk
        if missingFromDisk > 0 {
            Log.sync.warning("\(missingFromDisk) planned tracks missing from disk before add phase")
        }

        if !validToAdd.isEmpty {
            Log.sync.info("phase: adding (\(validToAdd.count) tracks)")
            let addStart = Date()
            state = .running(SyncProgress(phase: .adding, completed: 0, total: validToAdd.count, phaseStartedAt: addStart))

            // Artwork scratch dir for embedded-art fallback. Wiped at the
            // start of each sync so stale extracted images don't accumulate.
            // Files in here must outlive itdb_write — libgpod stores the path
            // in track->artwork and renders the bytes lazily during save.
            try? FileManager.default.removeItem(at: artworkScratchDir)
            try? FileManager.default.createDirectory(at: artworkScratchDir, withIntermediateDirectories: true)
            let locator = ArtworkLocator(scratchDir: artworkScratchDir)

            var artworkAttached = 0
            var artworkMissing = 0

            for (i, planned) in validToAdd.enumerated() {
                if cancelRequested { break }
                state = .running(SyncProgress(
                    phase: .adding,
                    completed: i,
                    total: validToAdd.count,
                    detail: "\(planned.library.artist) — \(planned.library.title)",
                    phaseStartedAt: addStart
                ))
                let props = await AudioMetadataReader.read(planned.sourceURL)
                // Resolve cover art per-track; ArtworkLocator caches by album
                // dir so each album's lookup runs once. The cover URL is
                // passed straight through to ipod_add_track_full so artwork
                // is wired up in the same atomic call as the track add — same
                // order as ipod-sync.c.
                let albumDir = planned.library.url.deletingLastPathComponent()
                let coverURL = await locator.locate(
                    albumDir: albumDir,
                    candidateAudioFile: planned.sourceURL
                )
                if coverURL == nil {
                    artworkMissing += 1
                    Log.artwork.debug("no cover for \(planned.library.artist) / \(planned.library.album)")
                }
                do {
                    try await device.addTrack(
                        filepath: planned.sourceURL,
                        title: planned.library.title,
                        artist: planned.library.artist,
                        album: planned.library.album,
                        trackNumber: planned.library.trackNumber,
                        durationMS: props.durationMS,
                        bitrate: props.bitrate,
                        sampleRate: props.sampleRate,
                        filetype: props.filetypeString,
                        artworkPath: coverURL?.path
                    )
                    added += 1
                    if coverURL != nil { artworkAttached += 1 }
                } catch {
                    Log.sync.warning("add failed: \(planned.library.artist) — \(planned.library.title): \(error.localizedDescription)")
                    addFailed += 1
                }
            }
            state = .running(SyncProgress(phase: .adding, completed: added, total: validToAdd.count, phaseStartedAt: addStart))
            Log.sync.info("phase: adding done (\(added) ok, \(addFailed) failed) — artwork: \(artworkAttached) attached, \(artworkMissing) missing")
        }

        if cancelRequested {
            await finishCancelled(device: device, added: added, removed: removed,
                                  failed: addFailed + removeFailed,
                                  convertedFailures: convertedFailures)
            return
        }

        // 4. Playlists — wipe iPod's user playlists and rewrite from M3Us.
        let playlistOutcome = await syncPlaylists(
            playlists: playlists,
            changes: plan.playlistChanges,
            device: device
        )

        if cancelRequested {
            await finishCancelled(device: device, added: added, removed: removed,
                                  failed: addFailed + removeFailed,
                                  convertedFailures: convertedFailures,
                                  playlists: playlistOutcome)
            return
        }

        // 5. Save.
        Log.sync.info("phase: saving (writing iTunesDB + rendering thumbnails)")
        state = .running(SyncProgress(phase: .saving, completed: 0, total: 1))
        do {
            try await device.save()
        } catch {
            Log.sync.error("save failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return
        }

        let totalOnDevice = await device.trackCount()
        Log.sync.info("sync finished: added=\(added) removed=\(removed) skipped=\(plan.unchangedCount) failed=\(addFailed + removeFailed) totalOnDevice=\(totalOnDevice) playlists +\(playlistOutcome.added)/-\(playlistOutcome.removed)/~\(playlistOutcome.updated)")
        state = .finished(SyncOutcome(
            added: added,
            removed: removed,
            skipped: plan.unchangedCount,
            failed: addFailed + removeFailed,
            convertedFailures: convertedFailures,
            totalOnDevice: totalOnDevice,
            cancelled: false,
            playlistsAdded: playlistOutcome.added,
            playlistsRemoved: playlistOutcome.removed,
            playlistsUpdated: playlistOutcome.updated
        ))
    }

    /// Save whatever was accomplished and emit a `.finished(cancelled: true)` outcome.
    private func finishCancelled(
        device: IPodDevice,
        added: Int,
        removed: Int,
        failed: Int,
        convertedFailures: Int,
        playlists: PlaylistSyncOutcome = PlaylistSyncOutcome()
    ) async {
        Log.sync.info("finishing cancelled sync: saving partial progress")
        state = .running(SyncProgress(phase: .saving, completed: 0, total: 1))
        try? await device.save()
        let totalOnDevice = await device.trackCount()
        Log.sync.info("sync cancelled: added=\(added) removed=\(removed) failed=\(failed) totalOnDevice=\(totalOnDevice)")
        state = .finished(SyncOutcome(
            added: added,
            removed: removed,
            skipped: 0,
            failed: failed,
            convertedFailures: convertedFailures,
            totalOnDevice: totalOnDevice,
            cancelled: true,
            playlistsAdded: playlists.added,
            playlistsRemoved: playlists.removed,
            playlistsUpdated: playlists.updated
        ))
    }

    /// Tally of what the playlist phase actually did, for the finished summary.
    /// `nonisolated` so `finishCancelled` can default-construct one — default
    /// argument expressions are evaluated outside the actor.
    private nonisolated struct PlaylistSyncOutcome {
        var added = 0
        var removed = 0
        var updated = 0
    }

    /// Replace the iPod's user playlists with the contents of the M3U store.
    /// Each playlist is created fresh, then populated by matching every entry
    /// against the iPod's tracks via (artist, album, title) keys parsed out
    /// of the entry's relative path.
    ///
    /// `changes` is the plan's playlist diff — used only for the progress
    /// detail line and the finished tally. Every playlist is rewritten
    /// regardless of what it says.
    private func syncPlaylists(
        playlists: [Playlist],
        changes: [PlaylistChange],
        device: IPodDevice
    ) async -> PlaylistSyncOutcome {
        let total = playlists.count
        Log.sync.info("phase: playlists (\(total) playlists)")
        let plStart = Date()
        state = .running(SyncProgress(phase: .playlists, completed: 0, total: max(total, 1), phaseStartedAt: plStart))

        var changeByName: [String: PlaylistChange] = [:]
        for change in changes { changeByName[change.name] = change }
        var outcome = PlaylistSyncOutcome()

        // Always purge: keeps iPod state in sync with the M3U directory.
        let cleared = await device.clearUserPlaylists()
        Log.sync.debug("cleared \(cleared) existing user playlists from iPod")
        // Playlists with no .m3u backing them are gone as of the purge above —
        // nothing recreates them, so they count as removed right here.
        outcome.removed = changes.filter { $0.kind == .removed }.count

        guard total > 0 else {
            state = .running(SyncProgress(phase: .playlists, completed: 0, total: 1, phaseStartedAt: plStart))
            return outcome
        }

        let iPodTracks = await device.tracks()
        var idsByKey: [TrackKey: UInt32] = [:]
        for t in iPodTracks { idsByKey[TrackKey(ipod: t)] = t.id }

        for (i, playlist) in playlists.enumerated() {
            if cancelRequested { break }
            let change = changeByName[playlist.name]
            state = .running(SyncProgress(
                phase: .playlists,
                completed: i,
                total: total,
                detail: Self.playlistDetail(name: playlist.name, change: change),
                phaseStartedAt: plStart
            ))
            do {
                let playlistID = try await device.createPlaylist(name: playlist.name)
                var matched = 0
                var unmatched = 0
                for entry in playlist.entries {
                    guard let key = Self.playlistEntryKey(entry: entry) else {
                        unmatched += 1
                        continue
                    }
                    guard let trackID = idsByKey[key] else {
                        unmatched += 1
                        continue
                    }
                    try? await device.addTrackToPlaylist(playlistID: playlistID, trackID: trackID)
                    matched += 1
                }
                switch change?.kind {
                case .added: outcome.added += 1
                case .modified: outcome.updated += 1
                default: break
                }
                Log.sync.info("playlist \"\(playlist.name)\": \(matched) matched, \(unmatched) skipped (not on iPod)")
            } catch {
                Log.sync.warning("playlist \"\(playlist.name)\" failed: \(error.localizedDescription)")
                continue
            }
        }
        state = .running(SyncProgress(phase: .playlists, completed: total, total: total, phaseStartedAt: plStart))
        return outcome
    }

    /// Progress line for one playlist: the name plus what's happening to it,
    /// so the phase doesn't read as "rewriting everything" when only one
    /// playlist actually changed.
    private static func playlistDetail(name: String, change: PlaylistChange?) -> String {
        guard let change else { return name }
        switch change.kind {
        case .added:
            return "Adding \"\(name)\" (\(change.finalCount) tracks)"
        case .modified:
            var parts: [String] = []
            if change.entriesAdded > 0 { parts.append("+\(change.entriesAdded)") }
            if change.entriesRemoved > 0 { parts.append("−\(change.entriesRemoved)") }
            return "Updating \"\(name)\" (\(parts.joined(separator: " ")))"
        case .removed:
            return "Removing \"\(name)\""
        case .unchanged:
            return "\"\(name)\" (unchanged)"
        }
    }

    /// Parse an M3U entry path ("Artist/Album/01 - Title.flac") into a TrackKey
    /// that matches how iPod tracks are keyed.
    private static func playlistEntryKey(entry: PlaylistEntry) -> TrackKey? {
        let parts = entry.path.split(separator: "/")
        guard parts.count >= 3 else { return nil }
        let artist = String(parts[parts.count - 3])
        let album = String(parts[parts.count - 2])
        let basename = (String(parts[parts.count - 1]) as NSString).deletingPathExtension
        let title = LibraryScanner.parseFilename(basename).1
        return TrackKey(artist: artist, album: album, title: title)
    }

}

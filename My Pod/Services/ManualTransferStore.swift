import AVFoundation
import Foundation
import Observation

nonisolated struct ManualTransferOutcome: Sendable, Equatable {
    var added: Int = 0
    var removed: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var cancelled: Bool = false
}

@MainActor
@Observable
final class ManualTransferStore {
    enum State: Equatable {
        case idle
        case loading
        case adding(completed: Int, total: Int, detail: String)
        case removing(completed: Int, total: Int, detail: String)
        case artwork(completed: Int, total: Int, detail: String)
        case saving
        case finished(ManualTransferOutcome)
        case failed(String)
    }

    private(set) var queuedTracks: [LibraryTrack] = []
    private(set) var deviceTracks: [TrackInfo] = []

    /// Device tracks staged for deletion, applied on the next commit.
    ///
    /// Marked rather than deleted on click, so manual mode works the way library
    /// mode does: you assemble a set of changes, see what they cost, and apply
    /// them with one press. It also makes removal undoable right up until the
    /// moment it isn't.
    private(set) var markedForRemoval: Set<UInt32> = []

    var hasPendingChanges: Bool { !queuedTracks.isEmpty || !markedForRemoval.isEmpty }

    func markSelectedForRemoval() {
        guard !isBusy, !selectedDeviceTrackIDs.isEmpty else { return }
        markedForRemoval.formUnion(selectedDeviceTrackIDs)
        selectedDeviceTrackIDs.removeAll()
        recomputePending()
    }

    func unmarkForRemoval(_ ids: Set<UInt32>) {
        guard !isBusy, !ids.isEmpty else { return }
        markedForRemoval.subtract(ids)
        recomputePending()
    }

    func clearMarkedForRemoval() {
        guard !isBusy, !markedForRemoval.isEmpty else { return }
        markedForRemoval.removeAll()
        recomputePending()
    }

    func isMarkedForRemoval(_ track: TrackInfo) -> Bool { markedForRemoval.contains(track.id) }

    /// What the staged changes would add to and free from the iPod, for the
    /// storage bar's preview.
    ///
    /// Mirrors what `commit` will actually do rather than summing the queue
    /// naively: tracks already on the device are skipped there, so they mustn't
    /// be counted here, and sizes come from `estimatedIPodBytes`, which follows
    /// the connected iPod's ceiling — a FLAC bound for a lossless iPod is
    /// roughly 3x the size of the same file bound for an AAC one.
    ///
    /// Nothing is ever removed by adding, so the removing side stays zero;
    /// manual removals happen through their own explicit action.
    private(set) var pending = MusicLibraryStore.PendingBytes()

    /// Recomputed on every change to the queue or the device's contents, rather
    /// than computed in a view body — `estimatedIPodBytes` stats a cached file
    /// per track, which is not something to do on each redraw.
    private func recomputePending() {
        guard hasPendingChanges else {
            pending = MusicLibraryStore.PendingBytes()
            return
        }
        let conversion = ConversionService(ceiling: DeviceProfileStore.shared.active.ceiling)
        let onDevice = Set(deviceTracks.map { TrackKey(ipod: $0) })
        var adding: UInt64 = 0
        for track in queuedTracks where !onDevice.contains(TrackKey(library: track)) {
            adding &+= conversion.estimatedIPodBytes(for: track)
        }
        // Removals are exact — `TrackInfo.sizeBytes` is the iPod's own record of
        // the file it holds, not an estimate.
        var removing: UInt64 = 0
        for track in deviceTracks where markedForRemoval.contains(track.id) {
            removing &+= UInt64(track.sizeBytes)
        }
        pending = MusicLibraryStore.PendingBytes(adding: adding, removing: removing)
    }
    var selectedDeviceTrackIDs: Set<UInt32> = []
    var searchText = ""
    private(set) var state: State = .idle

    private var cancelRequested = false

    private let artworkScratchDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("My Pod/manual-artwork", isDirectory: true)
    }()

    var isBusy: Bool {
        switch state {
        case .loading, .adding, .removing, .artwork, .saving: true
        default: false
        }
    }

    var filteredDeviceTracks: [TrackInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return deviceTracks }
        return deviceTracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    func resetResult() {
        guard !isBusy else { return }
        state = .idle
    }

    func cancel() {
        guard isBusy else { return }
        Log.sync.warning("manual transfer cancel requested by user")
        cancelRequested = true
    }

    func refresh(device: IPodDevice?) async {
        guard let device else {
            deviceTracks = []
            recomputePending()
            selectedDeviceTrackIDs.removeAll()
            return
        }
        let tracks = await device.tracks()
        deviceTracks = tracks.sorted(by: Self.deviceTrackSort)
        recomputePending()
        selectedDeviceTrackIDs.formIntersection(Set(tracks.map(\.id)))
        markedForRemoval.formIntersection(Set(tracks.map(\.id)))
    }

    func enqueue(urls: [URL]) async {
        guard !urls.isEmpty, !isBusy else { return }
        state = .loading
        let discovered = await ManualTrackLoader.load(urls: urls)

        // A file can arrive more than once when, for example, the user drops
        // both an album folder and one of its tracks. Queue identity is the
        // canonicalized source path; iPod duplicate identity is checked again
        // at commit time with TrackKey.
        var byPath = Dictionary(uniqueKeysWithValues: queuedTracks.map { ($0.url.standardizedFileURL.path, $0) })
        for track in discovered {
            byPath[track.url.standardizedFileURL.path] = track
        }
        queuedTracks = byPath.values.sorted(by: Self.libraryTrackSort)
        recomputePending()
        state = .idle
        Log.ui.info("manual queue: \(queuedTracks.count) tracks")
    }

    func removeQueued(url: URL) {
        guard !isBusy else { return }
        queuedTracks.removeAll { $0.url == url }
        recomputePending()
    }

    /// Drop a finished or failed result so the next run starts clean.
    ///
    /// Without this the sheet reopens showing the *last* transfer's outcome
    /// instead of what's queued now — the state is what drives which pane it
    /// renders. Mirrors `SyncEngine.reset`.
    func resetState() {
        guard !isBusy else { return }
        state = .idle
    }

    func clearQueue() {
        guard !isBusy else { return }
        queuedTracks.removeAll()
        recomputePending()
    }

    /// Apply everything staged: marked removals first, then queued additions,
    /// then one save.
    ///
    /// Removals lead for the same reason `SyncEngine` orders them that way —
    /// they free space the additions may need, so a device that is nearly full
    /// can still be rearranged in a single pass.
    ///
    /// Unlike the mirror this never *infers* a removal. Nothing is deleted
    /// because it happens to be absent locally; only what the user explicitly
    /// marked goes.
    /// `library` is only used to refresh cover art on albums the iPod already
    /// holds — manual mode has no selection, but it does have the same problem:
    /// artwork is attached when a track is added and never revisited, so a
    /// cover set afterwards would never reach the device. This is the mode's
    /// only commit point, so it's where the artwork queue drains.
    func commit(to device: IPodDevice, freeBytes: UInt64, library: MusicLibrary) async {
        guard hasPendingChanges, !isBusy else { return }
        cancelRequested = false

        let existing = await device.tracks()
        var existingKeys = Set(existing.map { TrackKey(ipod: $0) })
        let marked = deviceTracks.filter { markedForRemoval.contains($0.id) }
        var outcome = ManualTransferOutcome()

        // What the additions actually amount to, once anything already present
        // is discounted.
        var candidates: [LibraryTrack] = []
        for track in queuedTracks {
            let key = TrackKey(library: track)
            if existingKeys.contains(key) {
                outcome.skipped += 1
            } else {
                candidates.append(track)
                existingKeys.insert(key)
            }
        }
        // Rebuild, because a track counted as a candidate must not also read as
        // already-present when the loop below inserts it for real.
        existingKeys = Set(existing.map { TrackKey(ipod: $0) })

        let ceiling = DeviceProfileStore.shared.active.ceiling
        let conversionService = ConversionService(ceiling: ceiling)
        let requiredBytes = candidates.reduce(UInt64(0)) { total, track in
            total &+ conversionService.estimatedIPodBytes(for: track)
        }
        // Marked removals run first, so their space counts toward the budget.
        let freedBytes = marked.reduce(UInt64(0)) { $0 &+ UInt64($1.sizeBytes) }
        let budget = freeBytes &+ freedBytes
        guard requiredBytes <= budget else {
            let shortfall = requiredBytes - budget
            state = .failed(
                "This needs \(SyncEngine.byteString(shortfall)) more space than the iPod has, even after the removals."
            )
            return
        }

        // 1. Removals.
        for (index, track) in marked.enumerated() {
            if cancelRequested { break }
            state = .removing(
                completed: index,
                total: marked.count,
                detail: "\(track.artist) — \(track.title)"
            )
            do {
                try await device.removeTrack(trackID: track.id)
                outcome.removed += 1
            } catch {
                outcome.failed += 1
                Log.sync.warning("manual remove failed: \(track.artist) — \(track.title): \(error.localizedDescription)")
            }
        }

        // 2. Additions.
        if !candidates.isEmpty, !cancelRequested {
            try? FileManager.default.removeItem(at: artworkScratchDir)
            try? FileManager.default.createDirectory(at: artworkScratchDir, withIntermediateDirectories: true)
            let artworkLocator = ArtworkLocator(scratchDir: artworkScratchDir)

            for (index, track) in candidates.enumerated() {
                if cancelRequested { break }
                state = .adding(
                    completed: index,
                    total: candidates.count,
                    detail: "\(track.artist) — \(track.title)"
                )
                do {
                    let playableURL = try await conversionService.convert(track)
                    let props = await AudioMetadataReader.read(playableURL)
                    // Use the original source as the embedded-art candidate.
                    // Cached afconvert output intentionally carries no tags.
                    let artwork = await artworkLocator.locate(
                        albumDir: track.url.deletingLastPathComponent(),
                        candidateAudioFile: track.url
                    )
                    try await device.addTrack(
                        filepath: playableURL,
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        trackNumber: track.trackNumber,
                        durationMS: props.durationMS,
                        bitrate: props.bitrate,
                        sampleRate: props.sampleRate,
                        filetype: props.filetypeString,
                        artworkPath: artwork?.path
                    )
                    existingKeys.insert(TrackKey(library: track))
                    outcome.added += 1
                } catch {
                    outcome.failed += 1
                    Log.sync.warning("manual add failed: \(track.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // 3. Cover art for albums already on the device. Database edits only,
        // no file copies — see `ArtworkSync`.
        //
        // Against the *pre-commit* track list, minus what was just removed:
        // anything added moments ago already had its artwork attached during the
        // add, and re-pushing it here would write the same bytes twice.
        //
        // Only reached when something else is being committed — `hasPendingChanges`
        // guards this method, and refreshed artwork alone doesn't count as a
        // pending change yet. That arrives with the button that queues it.
        let profile = DeviceProfileStore.shared.active
        if !cancelRequested {
            let survivors = existing.filter { !markedForRemoval.contains($0.id) }
            let updates = ArtworkSync.updates(
                library: library,
                deviceTracks: survivors,
                queued: ArtworkSync.queued(for: profile),
                changedSince: ArtworkSync.baseline(for: profile)
            )
            if !updates.isEmpty {
                Log.artwork.info("manual: refreshing artwork for \(updates.count) album(s)")
                for (index, update) in updates.enumerated() {
                    if cancelRequested { break }
                    state = .artwork(
                        completed: index,
                        total: updates.count,
                        detail: "\(update.artist) — \(update.album)"
                    )
                    _ = await ArtworkSync.apply(update, to: device)
                }
            }
        }

        // 4. One save for the whole operation.
        outcome.cancelled = cancelRequested
        let saved = await saveAndFinish(device: device, outcome: outcome)
        if saved {
            // Same rule as the sync path: the baseline only moves after a save
            // that landed.
            ArtworkSync.markSynced(profile)
            ArtworkSync.clearQueue(for: profile)
            let committed = existingKeys
            queuedTracks.removeAll { committed.contains(TrackKey(library: $0)) }
            markedForRemoval.removeAll()
            selectedDeviceTrackIDs.removeAll()
            await refresh(device: device)
            recomputePending()
        }
    }

    private func saveAndFinish(device: IPodDevice, outcome: ManualTransferOutcome) async -> Bool {
        // Same invariant as SyncEngine cancellation: after the first database
        // mutation, every exit path saves. A cancelled manual operation is
        // partial progress, not an abandoned in-memory iTunesDB.
        state = .saving
        do {
            try await device.save()
            try? FileManager.default.removeItem(at: artworkScratchDir)
            state = .finished(outcome)
            Log.sync.info("manual operation finished: +\(outcome.added) -\(outcome.removed) skipped=\(outcome.skipped) failed=\(outcome.failed) cancelled=\(outcome.cancelled)")
            return true
        } catch {
            Log.sync.error("manual save failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return false
        }
    }

    private static func deviceTrackSort(_ lhs: TrackInfo, _ rhs: TrackInfo) -> Bool {
        if lhs.artist != rhs.artist {
            return lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
        }
        if lhs.album != rhs.album {
            return lhs.album.localizedCaseInsensitiveCompare(rhs.album) == .orderedAscending
        }
        if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
        if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func libraryTrackSort(_ lhs: LibraryTrack, _ rhs: LibraryTrack) -> Bool {
        if lhs.artist != rhs.artist {
            return lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
        }
        if lhs.album != rhs.album {
            return lhs.album.localizedCaseInsensitiveCompare(rhs.album) == .orderedAscending
        }
        if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

/// Turns arbitrary Finder files/folders into the same `LibraryTrack` value the
/// existing conversion pipeline consumes. Embedded title/artist/album metadata
/// wins; when tags are absent, filename + parent folders provide predictable
/// fallbacks instead of making manual transfer depend on a configured library.
nonisolated enum ManualTrackLoader {
    static func load(urls: [URL]) async -> [LibraryTrack] {
        let files = discoverAudioFiles(urls: urls)
        var tracks: [LibraryTrack] = []
        tracks.reserveCapacity(files.count)
        for file in files {
            if let track = await makeTrack(file) { tracks.append(track) }
        }
        return tracks
    }

    private static func discoverAudioFiles(urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var seen = Set<String>()

        func appendFile(_ url: URL) {
            guard AudioFormat.canSync(url.pathExtension) else { return }
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            out.append(url)
        }

        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let child as URL in enumerator {
                    let childValues = try? child.resourceValues(forKeys: [.isRegularFileKey])
                    if childValues?.isRegularFile == true { appendFile(child) }
                }
            } else if values?.isRegularFile == true {
                appendFile(url)
            }
        }
        return out
    }

    private static func makeTrack(_ url: URL) async -> LibraryTrack? {
        let ext = url.pathExtension.lowercased()
        guard AudioFormat.canSync(ext) else { return nil }

        let fallbackBase = url.deletingPathExtension().lastPathComponent
        let (fallbackNumber, fallbackTitle) = LibraryScanner.parseFilename(fallbackBase)
        let fallbackAlbum = url.deletingLastPathComponent().lastPathComponent
        let fallbackArtist = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent

        let common = await commonMetadata(url)
        let title = clean(common.title) ?? fallbackTitle
        let artist = clean(common.artist) ?? clean(fallbackArtist) ?? "Unknown Artist"
        let album = clean(common.album) ?? clean(fallbackAlbum) ?? "Unknown Album"
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
        let probe = AudioFormat.shouldProbe(ext) ? AudioProbe.read(url) : nil
        var format = AudioFormat.sourceFormat(ext: ext, probe: probe)

        if format.alwaysConverts, probe == nil {
            let source = FLACHeader.streamInfo(of: url)
            format.sampleRate = source.sampleRate
            format.bitDepth = source.bitDepth
            format.durationMS = source.durationMS
        }

        return LibraryTrack(
            id: url,
            artist: artist,
            album: album,
            trackNumber: fallbackNumber,
            title: title,
            fileExtension: ext,
            sizeBytes: size,
            format: format
        )
    }

    private static func commonMetadata(_ url: URL) async -> (title: String?, artist: String?, album: String?) {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return (nil, nil, nil) }

        func value(for key: AVMetadataKey) async -> String? {
            guard let item = items.first(where: { $0.commonKey == key }) else { return nil }
            return try? await item.load(.stringValue)
        }

        return (
            await value(for: .commonKeyTitle),
            await value(for: .commonKeyArtist),
            await value(for: .commonKeyAlbumName)
        )
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

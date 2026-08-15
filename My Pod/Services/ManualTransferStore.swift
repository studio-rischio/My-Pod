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
        case saving
        case finished(ManualTransferOutcome)
        case failed(String)
    }

    private(set) var queuedTracks: [LibraryTrack] = []
    private(set) var deviceTracks: [TrackInfo] = []
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
        case .loading, .adding, .removing, .saving: true
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
            selectedDeviceTrackIDs.removeAll()
            return
        }
        let tracks = await device.tracks()
        deviceTracks = tracks.sorted(by: Self.deviceTrackSort)
        selectedDeviceTrackIDs.formIntersection(Set(tracks.map(\.id)))
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
        state = .idle
        Log.ui.info("manual queue: \(queuedTracks.count) tracks")
    }

    func removeQueued(url: URL) {
        guard !isBusy else { return }
        queuedTracks.removeAll { $0.url == url }
    }

    func clearQueue() {
        guard !isBusy else { return }
        queuedTracks.removeAll()
    }

    /// Add only the queued tracks that are not already on the iPod. Unlike the
    /// mirror Sync engine, this method never derives a removal set from what is
    /// absent locally. Existing device tracks are therefore preserved unless
    /// the user explicitly removes them through `removeSelected`.
    func addQueued(to device: IPodDevice, freeBytes: UInt64) async {
        guard !queuedTracks.isEmpty, !isBusy else { return }
        cancelRequested = false

        let existing = await device.tracks()
        var existingKeys = Set(existing.map { TrackKey(ipod: $0) })
        var outcome = ManualTransferOutcome()
        var plannedKeys = existingKeys
        var candidates: [LibraryTrack] = []
        for track in queuedTracks {
            let key = TrackKey(library: track)
            guard !plannedKeys.contains(key) else {
                outcome.skipped += 1
                continue
            }
            plannedKeys.insert(key)
            candidates.append(track)
        }

        guard !candidates.isEmpty else {
            queuedTracks.removeAll { existingKeys.contains(TrackKey(library: $0)) }
            state = .finished(outcome)
            return
        }

        let ceiling = DeviceProfileStore.shared.active.ceiling
        let conversionService = ConversionService(ceiling: ceiling)

        let requiredBytes = candidates.reduce(UInt64(0)) { total, track in
            total &+ conversionService.estimatedIPodBytes(for: track)
        }
        guard requiredBytes <= freeBytes else {
            let shortfall = requiredBytes - freeBytes
            state = .failed(
                "This add needs \(SyncEngine.byteString(shortfall)) more space than the iPod has."
            )
            return
        }

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
                // Use the original source as the embedded-art candidate. Cached
                // afconvert output intentionally carries no tags or artwork.
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

        outcome.cancelled = cancelRequested
        let saved = await saveAndFinish(device: device, outcome: outcome)
        if saved {
            let committed = existingKeys
            queuedTracks.removeAll { committed.contains(TrackKey(library: $0)) }
            await refresh(device: device)
        }
    }

    /// Delete exactly the track IDs selected in the on-device browser. There
    /// is intentionally no library diff here: manual mode must never infer
    /// deletions from local files that happen not to be selected or present.
    func removeSelected(from device: IPodDevice) async {
        guard !selectedDeviceTrackIDs.isEmpty, !isBusy else { return }
        cancelRequested = false
        let selected = deviceTracks.filter { selectedDeviceTrackIDs.contains($0.id) }
        var outcome = ManualTransferOutcome()

        for (index, track) in selected.enumerated() {
            if cancelRequested { break }
            state = .removing(
                completed: index,
                total: selected.count,
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

        outcome.cancelled = cancelRequested
        let saved = await saveAndFinish(device: device, outcome: outcome)
        if saved {
            selectedDeviceTrackIDs.removeAll()
            await refresh(device: device)
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

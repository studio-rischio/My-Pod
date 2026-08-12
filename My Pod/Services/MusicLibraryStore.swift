import Foundation
import Observation
import SwiftUI

/// Owns the user's Plex-structured music library, sync selection, and tree
/// expansion state. Persists library root + selection across launches via
/// UserDefaults.
@MainActor
@Observable
final class MusicLibraryStore {
    enum ScanState: Equatable {
        case idle
        case scanning
        case ready(Date)
        case empty(URL)         // root chosen but no music found
    }

    private(set) var libraryRoot: URL?
    private(set) var library: MusicLibrary = .empty
    private(set) var scanState: ScanState = .idle

    /// File paths of tracks selected for sync. Source of truth — artist/album
    /// tristate is derived from this. Stored as paths (not URLs) to avoid the
    /// URL canonicalization issues that bit us when selection state went out of
    /// sync with the rendered tree.
    private(set) var selectedTrackPaths: Set<String> = []

    /// Names of currently-expanded artists.
    var expandedArtists: Set<String> = []

    /// "<artist>/<album>" composite keys for currently-expanded albums.
    var expandedAlbums: Set<String> = []

    /// Row IDs (artist:/album:/track: prefix) currently highlighted by the
    /// user via shift/cmd click. When the user clicks a checkbox on a row in
    /// this set AND there's more than one entry, the toggle applies to every
    /// highlighted row at once. Cleared when the library re-scans.
    var highlightedRowIDs: Set<String> = []

    /// Anchor row for shift-extend selection — the most recent
    /// non-shift highlight click. Persisted only in memory.
    @ObservationIgnored private var highlightAnchor: String?

    /// Pre-conversion state. UI shows progress + ETA while running.
    enum ConversionState: Equatable {
        case idle
        /// `startedAt` is the wall-clock moment the run kicked off; the view
        /// uses it together with `completed` to compute ETA via a TimelineView
        /// without the store needing its own timer.
        case running(completed: Int, total: Int, startedAt: Date)
        case finished(succeeded: Int, failed: Int, cancelled: Bool)
    }
    private(set) var conversionState: ConversionState = .idle

    /// Handle to the currently-running conversion task — cancelling it tells
    /// `ConversionService.ensure` to stop scheduling new jobs.
    @ObservationIgnored private var conversionTask: Task<Void, Never>?

    // MARK: - New music

    /// Last known state of the connected iPod. `nil` when nothing is attached
    /// — "new" means "not on the iPod", so without a device we can't say, and
    /// the tab shows no highlights at all rather than flagging everything.
    private(set) var deviceSnapshot: DeviceSnapshot?

    /// Library tracks absent from the connected iPod, plus the album/artist
    /// rows that contain them. Derived from `library` + `deviceSnapshot` and
    /// cached so tree rows can test membership without rebuilding a `TrackKey`
    /// (three string normalizations) on every redraw.
    private(set) var newTrackPaths: Set<String> = []
    private(set) var newAlbumIDs: Set<String> = []
    private(set) var newArtistNames: Set<String> = []

    var newTrackCount: Int { newTrackPaths.count }

    /// Tracks auto-selection has already checked for the user. Without this,
    /// every device refresh would re-check an album they'd deliberately
    /// unchecked — the album is still "new" (still not on the iPod), so it
    /// would keep qualifying. The offer is made once per track, not once per
    /// refresh. Tracks skipped for lack of space are deliberately *not*
    /// recorded, so they get another chance when room frees up.
    private(set) var autoOfferedPaths: Set<String> = []

    /// When on, new albums are checked for you as they appear, newest first,
    /// for as long as the device has room. Opt-out lives in the Music tab's
    /// Sync Selection panel.
    var autoSelectNewMusic: Bool {
        didSet {
            guard autoSelectNewMusic != oldValue else { return }
            defaults.set(autoSelectNewMusic, forKey: autoSelectKey)
            Log.library.info("auto-select new music: \(self.autoSelectNewMusic ? "on" : "off")")
            if autoSelectNewMusic { runAutoSelection() }
        }
    }

    private let defaults = UserDefaults.standard
    private let rootKey = "MyPod.libraryRoot"
    private let selectionKey = "MyPod.selectedTracks"
    private let autoSelectKey = "MyPod.autoSelectNewMusic"
    private let autoOfferedKey = "MyPod.autoOfferedTracks"

    init() {
        // Defaults to on for a fresh install — `object(forKey:)` distinguishes
        // "never set" from an explicit false, which `bool(forKey:)` can't.
        self.autoSelectNewMusic = defaults.object(forKey: autoSelectKey) as? Bool ?? true
        if let stored = defaults.array(forKey: autoOfferedKey) as? [String] {
            self.autoOfferedPaths = Set(stored)
        }
        if let path = defaults.string(forKey: rootKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                self.libraryRoot = url
            }
        }
        if let stored = defaults.array(forKey: selectionKey) as? [String] {
            self.selectedTrackPaths = Set(stored)
        }
        if libraryRoot != nil {
            rescan()
        }
    }

    // MARK: - Library root

    func chooseRoot(_ url: URL) {
        Log.library.info("library root chosen: \(url.path)")
        libraryRoot = url
        defaults.set(url.path, forKey: rootKey)
        rescan()
    }

    func clearRoot() {
        Log.library.info("library root cleared")
        libraryRoot = nil
        defaults.removeObject(forKey: rootKey)
        library = .empty
        scanState = .idle
    }

    func rescan() {
        guard let root = libraryRoot else { return }
        Log.library.info("scan started: \(root.path)")
        scanState = .scanning
        Task { [weak self] in
            let lib = await LibraryScanner.scan(root: root)
            guard let self else { return }
            self.library = lib
            self.scanState = lib.totalTracks == 0 ? .empty(root) : .ready(lib.scannedAt)
            self.pruneSelection(against: lib)
            Log.library.info("scan finished: \(lib.artists.count) artists, \(lib.totalTracks) tracks")
            self.recomputeNewMusic()
            self.runAutoSelection()
        }
    }

    // MARK: - Selection

    func toggleTrack(_ track: LibraryTrack) {
        let key = track.url.path
        let willBeOn: Bool
        if selectedTrackPaths.contains(key) {
            selectedTrackPaths.remove(key)
            willBeOn = false
        } else {
            selectedTrackPaths.insert(key)
            willBeOn = true
        }
        persistSelection()
        Log.library.debug("track \(willBeOn ? "+" : "-"): \(track.artist) — \(track.album) — \(track.title)")
    }

    func setAlbumSelected(_ album: LibraryAlbum, _ selected: Bool) {
        let before = album.tracks.lazy.filter { self.selectedTrackPaths.contains($0.url.path) }.count
        if selected {
            for t in album.tracks { selectedTrackPaths.insert(t.url.path) }
        } else {
            for t in album.tracks { selectedTrackPaths.remove(t.url.path) }
        }
        persistSelection()
        let delta = selected ? (album.tracks.count - before) : before
        Log.library.info("album \(selected ? "selected" : "deselected"): \(album.artist) — \(album.name) (\(delta) of \(album.tracks.count) tracks changed)")
    }

    func setArtistSelected(_ artist: LibraryArtist, _ selected: Bool) {
        var totalTracks = 0
        for album in artist.albums {
            for t in album.tracks {
                let key = t.url.path
                if selected { selectedTrackPaths.insert(key) } else { selectedTrackPaths.remove(key) }
                totalTracks += 1
            }
        }
        persistSelection()
        Log.library.info("artist \(selected ? "selected" : "deselected"): \(artist.name) (\(totalTracks) tracks)")
    }

    func selectAll() {
        var s: Set<String> = []
        for artist in library.artists {
            for album in artist.albums {
                for t in album.tracks { s.insert(t.url.path) }
            }
        }
        selectedTrackPaths = s
        persistSelection()
        Log.library.info("select all: \(s.count) tracks")
    }

    func clearSelection() {
        let prev = selectedTrackPaths.count
        selectedTrackPaths.removeAll()
        persistSelection()
        Log.library.info("clear selection (was \(prev) tracks)")
    }

    func isSelected(_ track: LibraryTrack) -> Bool {
        selectedTrackPaths.contains(track.url.path)
    }

    // MARK: - Highlight (multi-row selection scaffold)

    /// Row ID scheme:
    ///   `artist:<name>`
    ///   `album:<artist>/<album>`
    ///   `track:<absolute path>`
    /// Used by the tree view for click-to-select / shift-add / option-remove.
    static func artistRowID(_ a: LibraryArtist) -> String { "artist:" + a.name }
    static func albumRowID(_ a: LibraryAlbum) -> String { "album:" + a.artist + "/" + a.name }
    static func trackRowID(_ t: LibraryTrack) -> String { "track:" + t.url.path }

    /// Plain click — replace the highlight set with just this row.
    func setHighlight(_ rowID: String) {
        highlightedRowIDs = [rowID]
        highlightAnchor = rowID
        Log.library.debug("highlight = [\(rowID)]")
    }

    /// Shift-click — add to the highlight set (no range-extend; the user
    /// explicitly asked for additive single-row semantics, not Finder-style
    /// range select).
    func addToHighlight(_ rowID: String) {
        highlightedRowIDs.insert(rowID)
        highlightAnchor = rowID
        Log.library.debug("highlight + \(rowID) — now \(highlightedRowIDs.count) row(s)")
    }

    /// Option-click — remove from the highlight set.
    func removeFromHighlight(_ rowID: String) {
        highlightedRowIDs.remove(rowID)
        Log.library.debug("highlight - \(rowID) — now \(highlightedRowIDs.count) row(s)")
    }

    func clearHighlight() {
        guard !highlightedRowIDs.isEmpty else { return }
        Log.library.debug("highlight cleared")
        highlightedRowIDs.removeAll()
        highlightAnchor = nil
    }

    /// Apply `selected` (true → check, false → uncheck) to every highlighted
    /// row, fanning out to artist/album/track-level selection as appropriate.
    /// Used when the user clicks a checkbox on a row that's part of a
    /// multi-row highlight.
    func applyToHighlights(_ selected: Bool) {
        guard !highlightedRowIDs.isEmpty else { return }
        var artistsTouched = 0, albumsTouched = 0, tracksTouched = 0
        for rowID in highlightedRowIDs {
            if rowID.hasPrefix("artist:") {
                let name = String(rowID.dropFirst("artist:".count))
                guard let artist = library.artists.first(where: { $0.name == name }) else { continue }
                for album in artist.albums {
                    for t in album.tracks {
                        if selected { selectedTrackPaths.insert(t.url.path) }
                        else { selectedTrackPaths.remove(t.url.path) }
                    }
                }
                artistsTouched += 1
            } else if rowID.hasPrefix("album:") {
                let key = String(rowID.dropFirst("album:".count))
                guard let slash = key.firstIndex(of: "/") else { continue }
                let artistName = String(key[..<slash])
                let albumName = String(key[key.index(after: slash)...])
                guard let artist = library.artists.first(where: { $0.name == artistName }),
                      let album = artist.albums.first(where: { $0.name == albumName }) else { continue }
                for t in album.tracks {
                    if selected { selectedTrackPaths.insert(t.url.path) }
                    else { selectedTrackPaths.remove(t.url.path) }
                }
                albumsTouched += 1
            } else if rowID.hasPrefix("track:") {
                let path = String(rowID.dropFirst("track:".count))
                if selected { selectedTrackPaths.insert(path) }
                else { selectedTrackPaths.remove(path) }
                tracksTouched += 1
            }
        }
        persistSelection()
        Log.library.info("bulk \(selected ? "selected" : "deselected") \(highlightedRowIDs.count) highlighted rows (\(artistsTouched) artists, \(albumsTouched) albums, \(tracksTouched) tracks)")
    }

    // MARK: - Tristate helpers

    typealias CheckState = SelectionCheckState

    func state(for album: LibraryAlbum) -> CheckState {
        let total = album.tracks.count
        guard total > 0 else { return .off }
        let selected = self.selectedTrackPaths
        let on = album.tracks.lazy.filter { selected.contains($0.url.path) }.count
        if on == 0 { return .off }
        if on == total { return .on }
        return .mixed
    }

    func state(for artist: LibraryArtist) -> CheckState {
        let selected = self.selectedTrackPaths
        var anyOn = false, anyOff = false
        for album in artist.albums {
            for t in album.tracks {
                if selected.contains(t.url.path) { anyOn = true } else { anyOff = true }
                if anyOn && anyOff { return .mixed }
            }
        }
        return anyOn ? .on : .off
    }

    var selectionSize: UInt64 {
        let selected = selectedTrackPaths
        var total: UInt64 = 0
        for artist in library.artists {
            for album in artist.albums {
                for t in album.tracks where selected.contains(t.url.path) {
                    total &+= t.sizeBytes
                }
            }
        }
        return total
    }

    var selectionTrackCount: Int {
        selectedTrackPaths.count
    }

    // MARK: - Expansion

    func expansion(forArtist artist: LibraryArtist) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.expandedArtists.contains(artist.name) ?? false },
            set: { [weak self] newValue in
                guard let self else { return }
                if newValue { self.expandedArtists.insert(artist.name) }
                else { self.expandedArtists.remove(artist.name) }
            }
        )
    }

    func expansion(forAlbum album: LibraryAlbum) -> Binding<Bool> {
        let key = "\(album.artist)/\(album.name)"
        return Binding(
            get: { [weak self] in self?.expandedAlbums.contains(key) ?? false },
            set: { [weak self] newValue in
                guard let self else { return }
                if newValue { self.expandedAlbums.insert(key) }
                else { self.expandedAlbums.remove(key) }
            }
        )
    }

    // MARK: - Conversion

    /// Selected tracks (in library order) that aren't iPod-native.
    var selectedNeedingConversion: [LibraryTrack] {
        selectedLibraryTracks.filter { $0.needsConversion }
    }

    /// Selected non-native tracks that don't yet have an up-to-date cached
    /// .m4a version in the album's `.mypod/` folder.
    var pendingConversion: [LibraryTrack] {
        let svc = ConversionService()
        return selectedLibraryTracks.filter { $0.needsConversion && !svc.isCached($0) }
    }

    private var selectedLibraryTracks: [LibraryTrack] {
        let selected = selectedTrackPaths
        var out: [LibraryTrack] = []
        for artist in library.artists {
            for album in artist.albums {
                for t in album.tracks where selected.contains(t.url.path) {
                    out.append(t)
                }
            }
        }
        return out
    }

    /// Pre-convert all selected non-iPod-native tracks. With `force = false`
    /// (the default) tracks already cached at the current cache version are
    /// skipped; with `force = true` every selected track is re-encoded. The
    /// run is cancellable via `cancelConversion()` — in-flight afconvert
    /// processes finish naturally; the queue just stops scheduling new ones.
    func runConversion(force: Bool = false) {
        // `force` runs against the full selected non-native set; the
        // non-force path runs against the smaller pending-only subset.
        let tracks = force ? selectedNeedingConversion : pendingConversion
        guard !tracks.isEmpty else { return }
        if case .running = conversionState { return }
        Log.convert.info("pre-convert started\(force ? " (forced)" : ""): \(tracks.count) tracks")
        let startedAt = Date()
        conversionState = .running(completed: 0, total: tracks.count, startedAt: startedAt)

        let service = ConversionService()
        conversionTask = Task {
            let results = await service.ensure(tracks: tracks, force: force) { [weak self] completed, total in
                guard let store = self else { return }
                Task { @MainActor in
                    if case .running(_, _, let startedAt) = store.conversionState {
                        store.conversionState = .running(completed: completed, total: total, startedAt: startedAt)
                    }
                }
            }
            var succeeded = 0
            var failed = 0
            for (_, outcome) in results {
                switch outcome {
                case .success: succeeded += 1
                case .failure: failed += 1
                }
            }
            // Capture before the actor hop — Task.isCancelled reads from the
            // currently-executing Task; once we hop to MainActor we'd be in a
            // different Task's context.
            let cancelled = Task.isCancelled
            await MainActor.run { [weak self] in
                self?.conversionTask = nil
                self?.conversionState = .finished(succeeded: succeeded, failed: failed, cancelled: cancelled)
                Log.convert.info("pre-convert \(cancelled ? "cancelled" : "finished"): \(succeeded) ok, \(failed) failed")
            }
        }
    }

    /// Cancel the in-flight conversion. In-flight afconvert subprocesses run
    /// to completion (so we don't leave half-written m4a files behind); the
    /// queue just stops scheduling new jobs.
    func cancelConversion() {
        guard case .running = conversionState else { return }
        Log.convert.info("cancel requested by user")
        conversionTask?.cancel()
    }

    // MARK: - New music

    /// Called when the iPod connects, refreshes, or goes away. Recomputes what
    /// counts as new and — if enabled — checks whatever fits.
    func applyDeviceSnapshot(_ snapshot: DeviceSnapshot?) {
        guard snapshot != deviceSnapshot else { return }
        deviceSnapshot = snapshot
        recomputeNewMusic()
        runAutoSelection()
    }

    private func recomputeNewMusic() {
        guard let snapshot = deviceSnapshot else {
            newTrackPaths = []
            newAlbumIDs = []
            newArtistNames = []
            return
        }
        var paths: Set<String> = []
        var albumIDs: Set<String> = []
        var artistNames: Set<String> = []
        for artist in library.artists {
            for album in artist.albums {
                for t in album.tracks where snapshot.bytesByTrackKey[TrackKey(library: t)] == nil {
                    paths.insert(t.url.path)
                    albumIDs.insert(album.id)
                    artistNames.insert(artist.name)
                }
            }
        }
        newTrackPaths = paths
        newAlbumIDs = albumIDs
        newArtistNames = artistNames
        Log.library.info("new music: \(paths.count) tracks across \(albumIDs.count) albums")
    }

    /// Check new music that fits, newest album folder first.
    ///
    /// The unit is "the new tracks of one album", all-or-nothing: an album
    /// that doesn't fit is skipped and we carry on down the list, so a smaller
    /// album further along can still get in. Tracks already on the iPod are
    /// left exactly as the user left them — if they've unchecked something,
    /// re-checking it here would fight them.
    private func runAutoSelection() {
        guard autoSelectNewMusic,
              let snapshot = deviceSnapshot,
              !newTrackPaths.isEmpty else { return }

        let conversion = ConversionService()
        let selected = selectedLibraryTracks
        var budget = Int64(bitPattern: snapshot.freeBytes)

        // Space the next sync hands back: iPod tracks no longer checked get
        // removed, so their bytes are available to us.
        let selectedKeys = Set(selected.map { TrackKey(library: $0) })
        for (key, bytes) in snapshot.bytesByTrackKey where !selectedKeys.contains(key) {
            budget += Int64(bitPattern: bytes)
        }
        // Space already spoken for: checked tracks that haven't synced yet.
        for track in selected where snapshot.bytesByTrackKey[TrackKey(library: track)] == nil {
            budget -= Int64(bitPattern: conversion.estimatedIPodBytes(for: track))
        }

        // Newest folder first, so recent additions win the space on a device
        // that can't hold everything. ID breaks date ties so runs are stable.
        let candidateAlbums = library.artists
            .flatMap(\.albums)
            .filter { newAlbumIDs.contains($0.id) }
            .sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            }

        var chosenAlbums = 0, chosenTracks = 0, skippedAlbums = 0
        for album in candidateAlbums {
            let candidates = album.tracks.filter {
                newTrackPaths.contains($0.url.path)
                    && !selectedTrackPaths.contains($0.url.path)
                    && !autoOfferedPaths.contains($0.url.path)
            }
            guard !candidates.isEmpty else { continue }
            let cost = candidates.reduce(Int64(0)) {
                $0 + Int64(bitPattern: conversion.estimatedIPodBytes(for: $1))
            }
            guard cost <= budget else {
                skippedAlbums += 1
                continue
            }
            for t in candidates {
                selectedTrackPaths.insert(t.url.path)
                autoOfferedPaths.insert(t.url.path)
            }
            budget -= cost
            chosenAlbums += 1
            chosenTracks += candidates.count
        }

        guard chosenTracks > 0 || skippedAlbums > 0 else { return }
        if chosenTracks > 0 {
            persistSelection()
            persistAutoOffered()
        }
        Log.library.info("auto-selected \(chosenTracks) new tracks in \(chosenAlbums) albums; \(skippedAlbums) albums didn't fit (\(budget) bytes left)")
    }

    // MARK: - Persistence

    private func persistSelection() {
        defaults.set(Array(selectedTrackPaths), forKey: selectionKey)
    }

    private func persistAutoOffered() {
        defaults.set(Array(autoOfferedPaths), forKey: autoOfferedKey)
    }

    private func pruneSelection(against lib: MusicLibrary) {
        let allPaths: Set<String> = Set(
            lib.artists.flatMap { $0.albums.flatMap { $0.tracks.map { $0.url.path } } }
        )
        selectedTrackPaths.formIntersection(allPaths)
        persistSelection()
        // Keep the offered set from growing forever as files come and go. A
        // track that leaves the library and later returns gets offered again,
        // which is the right call — it's new to the iPod all over again.
        autoOfferedPaths.formIntersection(allPaths)
        persistAutoOffered()
        // Highlight set may reference rows that no longer exist after a
        // rescan — drop the whole thing rather than try to repair it.
        clearHighlight()
    }
}

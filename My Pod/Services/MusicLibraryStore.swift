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

    /// Whose selection is being edited, and at what quality. The default
    /// profile whenever no iPod is connected.
    ///
    /// The library itself is *not* per-profile — one music folder, scanned once,
    /// serves every device. Only what's ticked and what it converts to differ,
    /// which is why switching devices costs a recompute rather than a rescan.
    private(set) var profile: DeviceProfile = .defaultProfile

    var ceiling: ConversionCeiling { profile.ceiling }

    /// A conversion service for the active profile. Cheap to make — it's a
    /// value type — but it must never be constructed without a ceiling, or it
    /// would silently answer for the wrong iPod.
    var conversion: ConversionService { ConversionService(ceiling: ceiling) }

    /// How much of the library syncs. Mirrors iTunes, where the same choice
    /// governed both playlists and per-item checkboxes: in `.entireLibrary`
    /// every track and every playlist goes, and the checkboxes in both tabs are
    /// inert. Lives here rather than in a settings object of its own because
    /// everything it changes is downstream of `effectiveSelectedPaths`.
    enum SyncMode: String {
        case entireLibrary
        case selected
    }

    var syncMode: SyncMode {
        didSet {
            guard syncMode != oldValue else { return }
            defaults.set(syncMode.rawValue, forKey: syncModeKey)
            Log.library.info("sync mode: \(self.syncMode.rawValue)")
            recomputeEffectiveSelection()
        }
    }

    /// File paths of tracks the user checked by hand. Persisted, and the source
    /// of truth for what a checkbox *writes*. Stored as paths (not URLs) to
    /// avoid the URL canonicalization issues that bit us when selection state
    /// went out of sync with the rendered tree.
    ///
    /// Read `effectiveSelectedPaths` instead when you want to know what will
    /// actually sync — a track can be on because a checked playlist needs it,
    /// or because the mode is `.entireLibrary`, without ever appearing here.
    private(set) var selectedTrackPaths: Set<String> = []

    /// Library paths pulled in by checked playlists. Derived, never persisted:
    /// it's recomputed from the playlist store's selection whenever that or the
    /// library changes.
    private(set) var playlistDerivedPaths: Set<String> = []

    /// What a sync will actually copy — the union of the manual checkboxes and
    /// the playlists' contents, or the whole library in `.entireLibrary` mode.
    ///
    /// Stored rather than computed on demand: `state(for:)` runs per tree row,
    /// and unioning two multi-thousand-element sets on every redraw of every
    /// row is not free. Recomputed from `selectionDidChange()`, which every
    /// mutation path already funnels through.
    private(set) var effectiveSelectedPaths: Set<String> = []

    /// Every track path in the scanned library. Cached at scan time because
    /// `.entireLibrary` mode and playlist path resolution both need it.
    @ObservationIgnored private var allLibraryPaths: Set<String> = []

    /// What the pending sync would add to and free from the device, estimated
    /// live from the current selection. Drives the storage bar's preview.
    ///
    /// Deliberately the same arithmetic `SyncEngine.computePlan` does, so the
    /// bar and the sync sheet can't disagree: a selected track the device
    /// doesn't hold is an addition, a track the device holds that isn't
    /// selected is a removal.
    struct PendingBytes: Equatable {
        var adding: UInt64 = 0
        var removing: UInt64 = 0
        var isEmpty: Bool { adding == 0 && removing == 0 }
    }
    private(set) var pending = PendingBytes()

    /// Memo for `estimatedIPodBytes`, which stats the cached `.m4a` for anything
    /// already converted. Without this, every checkbox click would re-stat every
    /// selected track.
    ///
    /// Cleared whenever a cached file might have appeared or changed: after a
    /// rescan, and after a pre-conversion run. The second matters more than it
    /// looks — converting is exactly when a guessed size becomes a measurable
    /// one, so a stale memo would pin the bar to its least accurate answer.
    @ObservationIgnored private var estimateCache: [String: UInt64] = [:]
    /// Rebuilt, not just consulted, whenever the cache location or conversion
    /// profile changes: the service captures both at init, so keeping one
    /// instance for the app's lifetime would answer "is this cached?" against
    /// wherever the cache used to be.
    @ObservationIgnored private var conversionForEstimates = ConversionService(ceiling: .current)

    /// Path → track, rebuilt at scan time so the inspector can resolve a
    /// highlighted row without walking the whole library on every redraw.
    @ObservationIgnored private var tracksByPath: [String: LibraryTrack] = [:]

    /// Playlist-resolved paths exactly as the playlist store handed them over,
    /// kept so a rescan can re-resolve them against the new library without
    /// asking for them again.
    @ObservationIgnored private var rawPlaylistPaths: Set<String> = []

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

    private let defaults = UserDefaults.standard
    private let rootKey = "MyPod.libraryRoot"

    /// Per-profile, so two iPods can sync different music. Namespaced by the
    /// profile's stable UUID rather than held inside the profile record: these
    /// are thousands of paths rewritten on every checkbox click, and storing
    /// them in the shared blob would rewrite every device's state to save one.
    private var selectionKey: String { profile.storageKey(Self.selectionName) }
    private var syncModeKey: String { profile.storageKey(Self.syncModeName) }

    fileprivate static let selectionName = "selectedTracks"
    fileprivate static let syncModeName = "syncMode"

    init() {
        Self.migrateGlobalSelectionIfNeeded()
        let defaultProfile = DeviceProfile.defaultProfile
        // Existing installs have a selection they built by hand, so the default
        // has to be `.selected` — defaulting to `.entireLibrary` would quietly
        // widen every upgrader's next sync to their whole library.
        self.syncMode = UserDefaults.standard.string(forKey: defaultProfile.storageKey(Self.syncModeName))
            .flatMap(SyncMode.init(rawValue:)) ?? .selected
        if let path = defaults.string(forKey: rootKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                self.libraryRoot = url
            }
        }
        if let stored = defaults.array(forKey: defaultProfile.storageKey(Self.selectionName)) as? [String] {
            self.selectedTrackPaths = Set(stored)
        }
        // Both before anything reads the cache. 1.5 kept output from different
        // sample rates side by side under suffixed paths, so a 1.5 install that
        // had raised its limits is holding files the later rules would misread;
        // and ≤1.6 kept a single flat cache, which now lives one folder deeper.
        ConversionCeiling.migrate(libraryRoot: libraryRoot)
        CacheLocation.migrateLayoutIfNeeded(libraryRoot: libraryRoot)
        // `allLibraryPaths` is still empty here, so `.entireLibrary` resolves to
        // nothing until the scan lands and recomputes — which is correct: there
        // is no library yet to select all of.
        recomputeEffectiveSelection()
        // Moving or clearing the cache changes which tracks count as converted,
        // which changes both the pre-convert counts and the storage bar's
        // estimates. Settings is a separate scene with no reference to this
        // store, so the signal comes through NotificationCenter.
        NotificationCenter.default.addObserver(
            forName: CacheLocation.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cacheLayoutChanged() }
        }
        // Deliberately no observer for `ConversionCeiling.didChange`. The scan
        // records what each file *is* rather than what should happen to it, so
        // a quality change — or a different iPod being plugged in — is a
        // recompute, not a filesystem walk. The ceiling arrives via `activate`.
        if libraryRoot != nil {
            rescan()
        }
    }

    // MARK: - Profiles

    /// Switch to another iPod's settings and selection.
    ///
    /// No rescan: the library is device-independent, so only the derived sets
    /// change. That's what makes plugging in a different iPod feel instant
    /// rather than like a settings change.
    func activate(_ newProfile: DeviceProfile) {
        let ceilingChanged = newProfile.ceiling != profile.ceiling
        let profileChanged = newProfile.key != profile.key
        guard ceilingChanged || profileChanged else { return }
        profile = newProfile

        if profileChanged {
            selectedTrackPaths = Set(defaults.array(forKey: selectionKey) as? [String] ?? [])
            // Assigning `syncMode` writes through to the *new* profile's key,
            // which is correct — `profile` is already updated. The didSet is a
            // no-op when both profiles agree, hence the explicit recompute below.
            syncMode = defaults.string(forKey: syncModeKey)
                .flatMap(SyncMode.init(rawValue:)) ?? .selected
            // Deliberately *not* intersected against the scanned library here.
            // An iPod can connect before the first scan lands, and intersecting
            // against a library that is still empty would silently delete the
            // device's entire selection — and then persist it. Pruning already
            // happens on every scan, which is the only moment the library is
            // actually known.
        }
        if ceilingChanged {
            // Which tracks convert, and how big they land, both moved.
            cacheLayoutChanged()
        }
        recomputeEffectiveSelection()
        Log.library.info("editing \(newProfile.isDefault ? "default settings" : "\"\(newProfile.displayName)\"") — \(self.selectedTrackPaths.count) tracks ticked, \(newProfile.ceiling.rawValue)")
    }

    /// Give a newly-seen iPod the default profile's selection, so a second
    /// device starts from what the first one syncs rather than from nothing.
    static func copySelection(from source: DeviceProfile, to destination: DeviceProfile) {
        let defaults = UserDefaults.standard
        for name in [selectionName, syncModeName] {
            let value = defaults.object(forKey: source.storageKey(name))
            defaults.set(value, forKey: destination.storageKey(name))
        }
    }

    static func forgetSelection(for profile: DeviceProfile) {
        let defaults = UserDefaults.standard
        for name in [selectionName, syncModeName] {
            defaults.removeObject(forKey: profile.storageKey(name))
        }
    }

    /// One-time move of the app-wide selection onto the default profile.
    ///
    /// The old keys are left in place rather than removed: they cost a few
    /// kilobytes, and leaving them means downgrading to 1.6 still finds the
    /// selection it wrote. The one-shot flag is what stops a later re-upgrade
    /// clobbering per-profile edits with the stale global copy.
    private static func migrateGlobalSelectionIfNeeded() {
        let defaults = UserDefaults.standard
        let flag = "MyPod.profilesMigrated"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        let target = DeviceProfile.defaultProfile
        var moved = 0
        for (old, name) in [("MyPod.selectedTracks", selectionName), ("MyPod.syncMode", syncModeName)] {
            guard let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: target.storageKey(name))
            moved += 1
        }
        guard moved > 0 else { return }
        Log.library.info("moved the app-wide sync selection onto the default iPod profile")
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
        allLibraryPaths = []
        resolvePlaylistPaths()
        recomputeEffectiveSelection()
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
        }
    }

    // MARK: - Effective selection

    private func recomputeEffectiveSelection() {
        switch syncMode {
        case .entireLibrary:
            effectiveSelectedPaths = allLibraryPaths
        case .selected:
            effectiveSelectedPaths = selectedTrackPaths.union(playlistDerivedPaths)
        }
        recomputePending()
    }

    private func estimatedBytes(for track: LibraryTrack) -> UInt64 {
        let path = track.url.path
        if let hit = estimateCache[path] { return hit }
        let value = conversionForEstimates.estimatedIPodBytes(for: track)
        estimateCache[path] = value
        return value
    }

    /// The converted-file cache moved, was emptied, or changed shape.
    private func cacheLayoutChanged() {
        conversionForEstimates = ConversionService(ceiling: ceiling)
        estimateCache.removeAll(keepingCapacity: true)
        recomputePending()
        Log.library.info("cache layout changed — size estimates recomputed")
    }

    private func recomputePending() {
        guard let snapshot = deviceSnapshot else {
            pending = PendingBytes()
            return
        }
        var adding: UInt64 = 0
        var selectedKeys: Set<TrackKey> = []
        for artist in library.artists {
            for album in artist.albums {
                for t in album.tracks where effectiveSelectedPaths.contains(t.url.path) {
                    let key = TrackKey(library: t)
                    selectedKeys.insert(key)
                    if snapshot.bytesByTrackKey[key] == nil {
                        adding &+= estimatedBytes(for: t)
                    }
                }
            }
        }
        var removing: UInt64 = 0
        for (key, bytes) in snapshot.bytesByTrackKey where !selectedKeys.contains(key) {
            removing &+= bytes
        }
        pending = PendingBytes(adding: adding, removing: removing)
    }

    /// Take the set of library paths that checked playlists require.
    ///
    /// Pushed in from `ContentView` rather than read from the playlist store
    /// directly, matching how `applyDeviceSnapshot` already works — the two
    /// stores stay independent and the data flows one way.
    ///
    /// Paths arrive as written in the `.m3u`, which may carry either Unicode
    /// normalization: macOS hands out NFD, most other tools write NFC. They're
    /// canonicalized here against the scanned library, because this is the only
    /// place that knows what the real paths are.
    func applyPlaylistSelection(_ rawPaths: Set<String>) {
        rawPlaylistPaths = rawPaths
        resolvePlaylistPaths()
    }

    private func resolvePlaylistPaths() {
        var resolved: Set<String> = []
        resolved.reserveCapacity(rawPlaylistPaths.count)
        for raw in rawPlaylistPaths {
            // Anything that doesn't match points outside the library — a
            // playlist referencing a file that was moved or never scanned.
            // Dropping it here is what makes the "entries aren't in your
            // library" warning meaningful rather than a lie.
            if let match = canonicalLibraryPath(for: raw) {
                resolved.insert(match)
            }
        }
        guard resolved != playlistDerivedPaths else { return }
        let unresolved = rawPlaylistPaths.count - resolved.count
        playlistDerivedPaths = resolved
        recomputeEffectiveSelection()
        Log.playlist.info("playlist selection contributes \(resolved.count) library tracks\(unresolved > 0 ? " (\(unresolved) unresolved)" : "")")
    }

    /// Match one `.m3u` entry to the scanned library, or nil if it names a file
    /// the library doesn't contain.
    ///
    /// Two ways the same file gets two different path strings, and both have to
    /// be handled or checking a playlist silently selects nothing:
    ///
    /// **Unicode normalization.** macOS hands out NFD; most other tools write
    /// NFC. `Café` and `Café` are different `String`s.
    ///
    /// **Symlinks.** `LibraryScanner`'s enumerator yields fully resolved paths
    /// — a library under `/tmp` scans as `/private/tmp` — while an `.m3u` keeps
    /// whatever was written into it. Same file, no string match.
    ///
    /// The cheap comparisons run first and the filesystem is only touched when
    /// they all miss, so the common case costs three set lookups and no I/O.
    ///
    /// Note `realpath(3)` rather than `URL.resolvingSymlinksInPath()`: Foundation
    /// special-cases `/var`, `/tmp` and `/etc` by *stripping* a `/private`
    /// prefix, which is the opposite of what the enumerator produced, so it
    /// resolves this exact mismatch in the wrong direction.
    private func canonicalLibraryPath(for raw: String) -> String? {
        if let hit = matchIgnoringNormalization(raw) { return hit }
        guard let buffer = realpath(raw, nil) else { return nil }
        defer { free(buffer) }
        let resolved = String(cString: buffer)
        guard resolved != raw else { return nil }
        return matchIgnoringNormalization(resolved)
    }

    private func matchIgnoringNormalization(_ path: String) -> String? {
        if allLibraryPaths.contains(path) { return path }
        let pre = path.precomposedStringWithCanonicalMapping
        if allLibraryPaths.contains(pre) { return pre }
        let dec = path.decomposedStringWithCanonicalMapping
        if allLibraryPaths.contains(dec) { return dec }
        return nil
    }

    /// Whether this track syncs regardless of its own checkbox — because a
    /// checked playlist needs it, or because the whole library is going.
    /// The tree uses this to disable a checkbox that couldn't do anything.
    func isForced(_ track: LibraryTrack) -> Bool {
        switch syncMode {
        case .entireLibrary: true
        case .selected: playlistDerivedPaths.contains(track.url.path)
        }
    }

    /// True when per-track checkboxes can't change anything at all.
    var selectionIsLocked: Bool { syncMode == .entireLibrary }

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
        selectionDidChange()
        Log.library.debug("track \(willBeOn ? "+" : "-"): \(track.artist) — \(track.album) — \(track.title)")
    }

    func setAlbumSelected(_ album: LibraryAlbum, _ selected: Bool) {
        let before = album.tracks.lazy.filter { self.selectedTrackPaths.contains($0.url.path) }.count
        if selected {
            for t in album.tracks { selectedTrackPaths.insert(t.url.path) }
        } else {
            for t in album.tracks { selectedTrackPaths.remove(t.url.path) }
        }
        selectionDidChange()
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
        selectionDidChange()
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
        selectionDidChange()
        Log.library.info("select all: \(s.count) tracks")
    }

    func clearSelection() {
        let prev = selectedTrackPaths.count
        selectedTrackPaths.removeAll()
        selectionDidChange()
        Log.library.info("clear selection (was \(prev) tracks)")
    }

    /// Reflects what will sync, not just what the user ticked — a track a
    /// checked playlist needs reads as selected here.
    func isSelected(_ track: LibraryTrack) -> Bool {
        effectiveSelectedPaths.contains(track.url.path)
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

    /// What the highlighted rows actually are.
    ///
    /// Highlight is a separate axis from the checkboxes: it's what the user
    /// clicked, not what will sync. The inspector reads this; nothing about a
    /// sync does.
    enum HighlightedItem: Sendable {
        case artist(LibraryArtist)
        case album(LibraryAlbum)
        case track(LibraryTrack)
    }

    var highlightedItems: [HighlightedItem] {
        guard !highlightedRowIDs.isEmpty else { return [] }
        var byArtist: [String: LibraryArtist] = [:]
        byArtist.reserveCapacity(library.artists.count)
        for artist in library.artists { byArtist[artist.name] = artist }

        var out: [HighlightedItem] = []
        // Sorted so a multi-row summary is stable between redraws — the
        // underlying set has no order.
        for rowID in highlightedRowIDs.sorted() {
            if rowID.hasPrefix("artist:") {
                let name = String(rowID.dropFirst("artist:".count))
                if let artist = byArtist[name] { out.append(.artist(artist)) }
            } else if rowID.hasPrefix("album:") {
                let key = String(rowID.dropFirst("album:".count))
                guard let slash = key.firstIndex(of: "/") else { continue }
                let artistName = String(key[..<slash])
                let albumName = String(key[key.index(after: slash)...])
                if let album = byArtist[artistName]?.albums.first(where: { $0.name == albumName }) {
                    out.append(.album(album))
                }
            } else if rowID.hasPrefix("track:") {
                let path = String(rowID.dropFirst("track:".count))
                if let track = tracksByPath[path] { out.append(.track(track)) }
            }
        }
        return out
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
        selectionDidChange()
        Log.library.info("bulk \(selected ? "selected" : "deselected") \(highlightedRowIDs.count) highlighted rows (\(artistsTouched) artists, \(albumsTouched) albums, \(tracksTouched) tracks)")
    }

    // MARK: - Tristate helpers

    typealias CheckState = SelectionCheckState

    func state(for album: LibraryAlbum) -> CheckState {
        let total = album.tracks.count
        guard total > 0 else { return .off }
        let selected = self.effectiveSelectedPaths
        let on = album.tracks.lazy.filter { selected.contains($0.url.path) }.count
        if on == 0 { return .off }
        if on == total { return .on }
        return .mixed
    }

    func state(for artist: LibraryArtist) -> CheckState {
        let selected = self.effectiveSelectedPaths
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
        let selected = effectiveSelectedPaths
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
        effectiveSelectedPaths.count
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
        let svc = conversion
        return selectedLibraryTracks.filter { svc.needsConversion($0) }
    }

    /// Selected non-native tracks that don't yet have an up-to-date cached
    /// .m4a version in the album's `.mypod/` folder.
    var pendingConversion: [LibraryTrack] {
        let svc = conversion
        return selectedLibraryTracks.filter { svc.needsConversion($0) && !svc.isCached($0) }
    }

    private var selectedLibraryTracks: [LibraryTrack] {
        let selected = effectiveSelectedPaths
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

        let service = conversion
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
                // Converted files now exist, so `estimatedIPodBytes` can measure
                // them instead of guessing. Dropping the memo is what lets the
                // storage bar tighten from an estimate to the real size — without
                // it, pre-converting would leave the bar on its stalest guess.
                self?.estimateCache.removeAll(keepingCapacity: true)
                self?.recomputePending()
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
    }

    private func recomputeNewMusic() {
        defer { recomputePending() }
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

    // MARK: - Persistence

    /// Every mutation of `selectedTrackPaths` funnels through here, which is
    /// why the effective-selection recompute hangs off it rather than off each
    /// individual setter.
    private func selectionDidChange() {
        defaults.set(Array(selectedTrackPaths), forKey: selectionKey)
        recomputeEffectiveSelection()
    }

    private func pruneSelection(against lib: MusicLibrary) {
        let allPaths: Set<String> = Set(
            lib.artists.flatMap { $0.albums.flatMap { $0.tracks.map { $0.url.path } } }
        )
        // Cache before anything downstream reads it: `.entireLibrary` resolves
        // straight to this set, and playlist paths are canonicalized against it.
        allLibraryPaths = allPaths
        tracksByPath = Dictionary(
            lib.artists.lazy.flatMap { $0.albums }.flatMap { $0.tracks }.map { ($0.url.path, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        // A file may have been re-encoded or replaced since the last scan.
        estimateCache.removeAll(keepingCapacity: true)
        selectedTrackPaths.formIntersection(allPaths)
        // Re-resolve rather than intersect. A path that failed to match the old
        // library may match this one — a renamed folder, or a drive that came
        // back — and intersection alone would leave it dropped forever.
        resolvePlaylistPaths()
        selectionDidChange()
        // Highlight set may reference rows that no longer exist after a
        // rescan — drop the whole thing rather than try to repair it.
        clearHighlight()
    }
}

import Foundation
import Observation

enum PlaylistError: LocalizedError {
    case invalidName
    case nameInUse(String)
    case fileError(String)

    var errorDescription: String? {
        switch self {
        case .invalidName: "Playlist name can't be empty."
        case .nameInUse(let n): "A playlist named \"\(n)\" already exists."
        case .fileError(let m): "Couldn't write playlist: \(m)"
        }
    }
}

/// Owns the user's M3U playlists. Backed by a directory on disk
/// (default: `~/Music/MyPodPlaylists/`). Each playlist is one `.m3u` file.
@MainActor
@Observable
final class PlaylistStore {
    private(set) var directory: URL
    private(set) var playlists: [Playlist] = []
    private(set) var lastError: String?

    /// `Playlist.nameKey`s checked for sync. Source of truth for the
    /// checkboxes, and the filter `ContentView` applies before handing
    /// playlists to the sync engine. Keyed by name rather than `Playlist.id`
    /// because ids are regenerated on every `reload()`.
    private(set) var selectedNameKeys: Set<String> = []

    /// Playlists auto-selection has already offered. Same role as
    /// `MusicLibraryStore.autoOfferedPaths`: without it, a playlist the user
    /// deliberately unchecked would be re-checked on the next reload, since
    /// it's still "new" as far as the iPod is concerned.
    private(set) var offeredNameKeys: Set<String> = []

    /// Last known state of the connected iPod. `nil` when nothing is attached,
    /// in which case nothing is flagged as new — the same rule the Music tab
    /// follows.
    private(set) var deviceSnapshot: DeviceSnapshot?

    /// Name keys present in the store but not on the iPod.
    private(set) var newNameKeys: Set<String> = []

    /// When on, a playlist the app has never seen before starts out checked.
    var autoSelectNewPlaylists: Bool {
        didSet {
            guard autoSelectNewPlaylists != oldValue else { return }
            defaults.set(autoSelectNewPlaylists, forKey: autoSelectKey)
            Log.playlist.info("auto-select new playlists: \(self.autoSelectNewPlaylists ? "on" : "off")")
            if autoSelectNewPlaylists { offerUnseenPlaylists() }
        }
    }

    /// Whose playlist selection is being edited. Mirrors
    /// `MusicLibraryStore.profile` — the two always move together, driven from
    /// `ContentView`.
    private(set) var profile: DeviceProfile = .defaultProfile

    private let defaults = UserDefaults.standard
    /// Per-profile: an 8 GB nano and a 256 GB classic want different playlists
    /// on them, for the same reason they want different tracks.
    private var selectionKey: String { profile.storageKey(Self.selectionName) }
    private var offeredKey: String { profile.storageKey(Self.offeredName) }
    fileprivate static let selectionName = "selectedPlaylists"
    /// Per-profile too: "already offered" only means anything paired with the
    /// selection it was offered against.
    fileprivate static let offeredName = "offeredPlaylists"
    /// **Not** per-profile — a behaviour preference, not device state.
    private let autoSelectKey = "MyPod.autoSelectNewPlaylists"
    // Static so `init` can read it before the instance is fully initialized.
    private static let directoryKey = "MyPod.playlistDirectory"

    /// Where playlists live when the user has never chosen a folder.
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/MyPodPlaylists", isDirectory: true)
    }

    /// `directory` is an explicit argument only for tests; normal construction
    /// takes the user's stored choice, falling back to `defaultDirectory`.
    init(directory: URL? = nil) {
        Self.migrateGlobalSelectionIfNeeded()
        let stored = UserDefaults.standard.string(forKey: Self.directoryKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.directory = directory ?? stored ?? Self.defaultDirectory
        // `object(forKey:)` rather than `bool(forKey:)` so a fresh install
        // (never set) defaults to on while an explicit false is honoured.
        self.autoSelectNewPlaylists = defaults.object(forKey: autoSelectKey) as? Bool ?? true
        let defaultProfile = DeviceProfile.defaultProfile
        if let stored = defaults.array(forKey: defaultProfile.storageKey(Self.selectionName)) as? [String] {
            self.selectedNameKeys = Set(stored)
        }
        if let stored = defaults.array(forKey: defaultProfile.storageKey(Self.offeredName)) as? [String] {
            self.offeredNameKeys = Set(stored)
        }
        ensureDirectoryExists()
        reload()
    }

    // MARK: - Profiles

    /// Switch to another iPod's playlist selection. No reload — the `.m3u`
    /// files on disk are the same whichever device is attached.
    func activate(_ newProfile: DeviceProfile) {
        guard newProfile.key != profile.key else { return }
        profile = newProfile
        selectedNameKeys = Set(defaults.array(forKey: selectionKey) as? [String] ?? [])
        offeredNameKeys = Set(defaults.array(forKey: offeredKey) as? [String] ?? [])
        pruneSelection()
        // A playlist this device has never been offered should still be offered
        // now, exactly as if it had just appeared on disk.
        offerUnseenPlaylists()
        recomputeNew()
    }

    static func copySelection(from source: DeviceProfile, to destination: DeviceProfile) {
        let defaults = UserDefaults.standard
        for name in [selectionName, offeredName] {
            defaults.set(defaults.object(forKey: source.storageKey(name)), forKey: destination.storageKey(name))
        }
    }

    static func forgetSelection(for profile: DeviceProfile) {
        let defaults = UserDefaults.standard
        for name in [selectionName, offeredName] {
            defaults.removeObject(forKey: profile.storageKey(name))
        }
    }

    /// One-time move of the app-wide playlist selection onto the default
    /// profile. Old keys are left in place; see `MusicLibraryStore`'s twin.
    private static func migrateGlobalSelectionIfNeeded() {
        let defaults = UserDefaults.standard
        let flag = "MyPod.playlistProfilesMigrated"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        let target = DeviceProfile.defaultProfile
        for (old, name) in [("MyPod.selectedPlaylists", selectionName), ("MyPod.offeredPlaylists", offeredName)] {
            guard let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: target.storageKey(name))
        }
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Point the store at a different folder of `.m3u` files.
    ///
    /// Selection state deliberately survives the move. It's keyed by
    /// `Playlist.nameKey` rather than by path, so keys belonging to the old
    /// folder simply never match and sit inert — and a playlist in the new
    /// folder that happens to share a name with one you'd checked arrives
    /// checked. That's the same rule as renaming a file in place, which is the
    /// behaviour worth being consistent with. `offeredNameKeys` follows the
    /// same logic: a same-named playlist counts as already offered, so
    /// auto-select won't re-check something you unchecked before.
    func chooseDirectory(_ url: URL) {
        guard url != directory else { return }
        Log.playlist.info("playlist folder chosen: \(url.path)")
        directory = url
        defaults.set(url.path, forKey: Self.directoryKey)
        ensureDirectoryExists()
        reload()
    }

    func reload() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            playlists = []
            return
        }
        var loaded: [Playlist] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "m3u" || ext == "m3u8" else { continue }
            do {
                let parsed = try M3UParser.parse(url)
                let stem = url.deletingPathExtension().lastPathComponent
                let name = parsed.name?.isEmpty == false ? parsed.name! : stem
                loaded.append(Playlist(id: UUID(), name: name, entries: parsed.entries, fileURL: url))
            } catch {
                // Skip unreadable file.
            }
        }
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        playlists = loaded
        Log.playlist.info("loaded \(loaded.count) playlists from \(directory.path)")
        pruneSelection()
        offerUnseenPlaylists()
        recomputeNew()
    }

    // MARK: - Sync selection

    func isSelected(_ playlist: Playlist) -> Bool {
        selectedNameKeys.contains(playlist.nameKey)
    }

    func setSelected(_ playlist: Playlist, _ selected: Bool) {
        let key = playlist.nameKey
        guard selectedNameKeys.contains(key) != selected else { return }
        if selected { selectedNameKeys.insert(key) } else { selectedNameKeys.remove(key) }
        // Touching a playlist by hand counts as having been offered it, so
        // auto-selection won't re-check it later.
        offeredNameKeys.insert(key)
        persistSelection()
        Log.playlist.info("playlist \(selected ? "selected" : "deselected"): \"\(playlist.name)\"")
    }

    func toggleSelected(_ playlist: Playlist) {
        setSelected(playlist, !isSelected(playlist))
    }

    func selectAll() {
        selectedNameKeys = Set(playlists.map(\.nameKey))
        offeredNameKeys.formUnion(selectedNameKeys)
        persistSelection()
        Log.playlist.info("select all: \(self.selectedNameKeys.count) playlists")
    }

    func clearSelection() {
        let prev = selectedNameKeys.count
        selectedNameKeys.removeAll()
        offeredNameKeys.formUnion(playlists.map(\.nameKey))
        persistSelection()
        Log.playlist.info("clear playlist selection (was \(prev))")
    }

    /// The playlists a sync will actually write, in list order.
    var selectedPlaylists: [Playlist] {
        playlists.filter { selectedNameKeys.contains($0.nameKey) }
    }

    /// File paths every entry of every checked playlist points at.
    ///
    /// This is what makes checking a playlist put its music on the iPod, the
    /// way iTunes always behaved: the paths are handed to `MusicLibraryStore`,
    /// which unions them into the effective sync selection.
    ///
    /// Returned as written in the `.m3u` (resolved against `libraryRoot` for
    /// relative entries) and deliberately not normalized here — matching them
    /// to real files needs the scanned library, which lives on the other side.
    func selectedTrackPaths(libraryRoot: URL?) -> Set<String> {
        var paths: Set<String> = []
        for playlist in selectedPlaylists {
            for entry in playlist.entries {
                paths.insert(entry.resolvedURL(libraryRoot: libraryRoot).path)
            }
        }
        return paths
    }

    var selectionCount: Int { selectedPlaylists.count }

    /// State for the list header's select-all checkbox.
    var selectionState: SelectionCheckState {
        guard !playlists.isEmpty else { return .off }
        let on = selectionCount
        if on == 0 { return .off }
        if on == playlists.count { return .on }
        return .mixed
    }

    // MARK: - New playlists

    func isNew(_ playlist: Playlist) -> Bool {
        newNameKeys.contains(playlist.nameKey)
    }

    var newCount: Int { newNameKeys.count }

    /// Called when the iPod connects, refreshes, or goes away.
    func applyDeviceSnapshot(_ snapshot: DeviceSnapshot?) {
        guard snapshot?.playlistNameKeys != deviceSnapshot?.playlistNameKeys else {
            deviceSnapshot = snapshot
            return
        }
        deviceSnapshot = snapshot
        recomputeNew()
    }

    private func recomputeNew() {
        guard let snapshot = deviceSnapshot else {
            newNameKeys = []
            return
        }
        newNameKeys = Set(playlists.map(\.nameKey)).subtracting(snapshot.playlistNameKeys)
        Log.playlist.info("new playlists: \(self.newNameKeys.count) of \(self.playlists.count) not on iPod")
    }

    /// Check any playlist the app hasn't offered before. Unlike new music
    /// there's no space budget to respect — a playlist costs nothing until its
    /// tracks are checked in the Music tab, which is a separate decision.
    private func offerUnseenPlaylists() {
        guard autoSelectNewPlaylists else { return }
        var offered = 0
        for playlist in playlists where !offeredNameKeys.contains(playlist.nameKey) {
            selectedNameKeys.insert(playlist.nameKey)
            offeredNameKeys.insert(playlist.nameKey)
            offered += 1
        }
        guard offered > 0 else { return }
        persistSelection()
        Log.playlist.info("auto-selected \(offered) new playlist\(offered == 1 ? "" : "s")")
    }

    private func migrateSelection(from old: String, to new: String) {
        guard old != new else { return }
        if selectedNameKeys.remove(old) != nil { selectedNameKeys.insert(new) }
        if offeredNameKeys.remove(old) != nil { offeredNameKeys.insert(new) }
        persistSelection()
    }

    /// Drop selection/offered entries for playlists that no longer exist, so
    /// the defaults don't accumulate keys forever.
    private func pruneSelection() {
        let live = Set(playlists.map(\.nameKey))
        selectedNameKeys.formIntersection(live)
        offeredNameKeys.formIntersection(live)
        persistSelection()
    }

    private func persistSelection() {
        defaults.set(Array(selectedNameKeys), forKey: selectionKey)
        defaults.set(Array(offeredNameKeys), forKey: offeredKey)
    }

    // MARK: - CRUD

    @discardableResult
    func create(name: String) throws -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw PlaylistError.invalidName }
        guard !playlists.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw PlaylistError.nameInUse(trimmed)
        }
        let fileURL = directory.appendingPathComponent("\(trimmed).m3u")
        var playlist = Playlist(id: UUID(), name: trimmed, entries: [], fileURL: fileURL)
        try writeAndUpdate(&playlist)
        playlists.append(playlist)
        playlists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        offerUnseenPlaylists()
        recomputeNew()
        Log.playlist.info("created playlist \"\(trimmed)\"")
        return playlist
    }

    func delete(id: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let playlist = playlists[idx]
        try? FileManager.default.removeItem(at: playlist.fileURL)
        playlists.remove(at: idx)
        pruneSelection()
        recomputeNew()
        Log.playlist.info("deleted playlist \"\(playlist.name)\"")
    }

    func rename(id: UUID, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw PlaylistError.invalidName }
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        if playlists[idx].name == trimmed { return }
        if playlists.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw PlaylistError.nameInUse(trimmed)
        }
        let oldURL = playlists[idx].fileURL
        let newURL = directory.appendingPathComponent("\(trimmed).m3u")
        do {
            try? FileManager.default.removeItem(at: newURL)   // shouldn't exist; defensive
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            throw PlaylistError.fileError(error.localizedDescription)
        }
        let oldName = playlists[idx].name
        playlists[idx].name = trimmed
        playlists[idx].fileURL = newURL
        try writeAndUpdate(&playlists[idx])
        playlists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Selection is keyed by name, so carry it across the rename — otherwise
        // renaming would silently uncheck the playlist (and, with auto-select
        // on, immediately re-check it as if it were brand new).
        migrateSelection(from: Playlist.nameKey(oldName), to: Playlist.nameKey(trimmed))
        recomputeNew()
        Log.playlist.info("renamed \"\(oldName)\" → \"\(trimmed)\"")
    }

    // MARK: - Entry mutation

    func addEntries(playlistID: UUID, fileURLs: [URL], libraryRoot: URL?) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let name = playlists[idx].name
        for fileURL in fileURLs {
            let path = relativePath(of: fileURL, root: libraryRoot)
            playlists[idx].entries.append(PlaylistEntry(path: path))
        }
        try? writeAndUpdate(&playlists[idx])
        Log.playlist.info("\"\(name)\": added \(fileURLs.count) entries (total \(playlists[idx].entries.count))")
    }

    func removeEntries(playlistID: UUID, at offsets: IndexSet) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let name = playlists[idx].name
        let count = offsets.count
        for i in offsets.sorted(by: >) {
            playlists[idx].entries.remove(at: i)
        }
        try? writeAndUpdate(&playlists[idx])
        Log.playlist.info("\"\(name)\": removed \(count) entries")
    }

    func moveEntries(playlistID: UUID, from source: IndexSet, to destination: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var entries = playlists[idx].entries
        let moved = source.sorted(by: >).map { i -> PlaylistEntry in
            let e = entries.remove(at: i)
            return e
        }
        var insertAt = destination
        for offset in source where offset < destination { insertAt -= 1 }
        for entry in moved.reversed() {
            entries.insert(entry, at: max(0, min(insertAt, entries.count)))
        }
        playlists[idx].entries = entries
        try? writeAndUpdate(&playlists[idx])
    }

    // MARK: - Import

    /// Import an external `.m3u` / `.m3u8` file by copying it into the playlist
    /// directory. If the name collides, append " (n)".
    @discardableResult
    func importExternal(_ source: URL) throws -> Playlist {
        let baseName = source.deletingPathExtension().lastPathComponent
        var name = baseName
        var n = 2
        while playlists.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(baseName) (\(n))"
            n += 1
        }
        let dest = directory.appendingPathComponent("\(name).m3u")
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            throw PlaylistError.fileError(error.localizedDescription)
        }
        let parsed = try M3UParser.parse(dest)
        let playlist = Playlist(id: UUID(), name: name, entries: parsed.entries, fileURL: dest)
        playlists.append(playlist)
        playlists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        offerUnseenPlaylists()
        recomputeNew()
        Log.playlist.info("imported \"\(name)\" (\(parsed.entries.count) entries) from \(source.path)")
        return playlist
    }

    // MARK: - Helpers

    /// Convert an absolute file URL into a path relative to the library root if
    /// possible; otherwise return the absolute path.
    private func relativePath(of url: URL, root: URL?) -> String {
        guard let root else { return url.path }
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        if p.hasPrefix(rootPath) {
            return String(p.dropFirst(rootPath.count))
        }
        return p
    }

    private func writeAndUpdate(_ playlist: inout Playlist) throws {
        do {
            try M3UParser.write(playlist)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw PlaylistError.fileError(error.localizedDescription)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct PlaylistsView: View {
    @Bindable var playlistStore: PlaylistStore
    @Bindable var libraryStore: MusicLibraryStore

    @State private var selection: UUID?
    @State private var renamingID: UUID?
    @State private var draftName: String = ""
    @State private var creating: Bool = false
    @State private var newName: String = ""
    @State private var error: String?

    var body: some View {
        HSplitView {
            playlistList
                .frame(minWidth: 220, idealWidth: 260)
            editor
                .frame(minWidth: 360)
        }
        .alert("Playlist error", isPresented: errorBinding, presenting: error) { _ in
            Button("OK", role: .cancel) { error = nil }
        } message: { msg in
            Text(msg)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    }

    // MARK: - Left: list of playlists

    private var playlistList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TristateCheckbox(state: playlistStore.selectionState) {
                    // Same rule as the library tree: mixed resolves to on.
                    if playlistStore.selectionState == .on {
                        playlistStore.clearSelection()
                    } else {
                        playlistStore.selectAll()
                    }
                }
                .help("Check every playlist for sync")
                .disabled(playlistStore.playlists.isEmpty)

                Text("Playlists")
                    .font(.headline)

                Spacer()

                if playlistStore.newCount > 0 {
                    Label("\(playlistStore.newCount) new", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .imageScale(.small)
                        .monospacedDigit()
                        .help("Playlists that aren't on the iPod yet")
                }

                Menu {
                    Button("Select All") { playlistStore.selectAll() }
                        .disabled(playlistStore.playlists.isEmpty)
                    Button("Deselect All") { playlistStore.clearSelection() }
                        .disabled(playlistStore.selectionCount == 0)
                    Divider()
                    Toggle("Select new playlists automatically", isOn: $playlistStore.autoSelectNewPlaylists)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Selection options")

                Button {
                    creating = true
                    newName = ""
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Create a new playlist")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(selection: $selection) {
                if creating {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list").foregroundStyle(.secondary)
                        TextField("New Playlist", text: $newName, onCommit: commitNewPlaylist)
                            .textFieldStyle(.roundedBorder)
                        Button("Cancel") {
                            creating = false
                            newName = ""
                        }
                        .buttonStyle(.borderless)
                    }
                }
                ForEach(playlistStore.playlists) { playlist in
                    PlaylistRow(
                        playlist: playlist,
                        checkState: playlistStore.isSelected(playlist) ? .on : .off,
                        isNew: playlistStore.isNew(playlist),
                        isRenaming: renamingID == playlist.id,
                        draftName: $draftName,
                        onToggle: { playlistStore.toggleSelected(playlist) },
                        onCommitRename: commitRename,
                        onCancelRename: { renamingID = nil }
                    )
                    .tag(playlist.id)
                    .contextMenu {
                        Button(playlistStore.isSelected(playlist) ? "Don't Sync" : "Sync to iPod") {
                            playlistStore.toggleSelected(playlist)
                        }
                        Divider()
                        Button("Rename") { startRename(playlist) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([playlist.fileURL]) }
                        Divider()
                        Button("Delete", role: .destructive) { playlistStore.delete(id: playlist.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .dropDestination(for: URL.self) { urls, _ in
                handleListDrop(urls)
                return true
            } isTargeted: { _ in }

            HStack {
                Text("\(playlistStore.selectionCount) of \(playlistStore.playlists.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("Only checked playlists are written to the iPod")
                Spacer()
                Text(playlistStore.directory.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .help(playlistStore.directory.path)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }

    // MARK: - Right: selected playlist editor

    @ViewBuilder
    private var editor: some View {
        if let id = selection, let playlist = playlistStore.playlists.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(playlist.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    if playlistStore.isNew(playlist) {
                        Text("New")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                            .help("Not on the iPod yet")
                    }
                    Spacer()
                    Text("\(playlist.trackCount) tracks")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                HStack(spacing: 8) {
                    Toggle("Sync this playlist to the iPod", isOn: Binding(
                        get: { playlistStore.isSelected(playlist) },
                        set: { playlistStore.setSelected(playlist, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer()
                    if playlistStore.isSelected(playlist), unsyncedEntryCount(playlist) > 0 {
                        Label("\(unsyncedEntryCount(playlist)) won't sync", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("These entries point at tracks that aren't checked in the Music tab, so the iPod copy will skip them.")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Divider()

                if playlist.entries.isEmpty {
                    emptyDropTarget(playlistID: id)
                } else {
                    entryList(for: playlist)
                }

                Divider()

                Text("Drop tracks from the Library tab onto this list to add them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)
                Text("Select a playlist")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Whether a sync would actually write this entry. The engine resolves
    /// entries against what ends up on the iPod, and only tracks checked in
    /// the Music tab get there — so an entry whose file isn't in the library
    /// selection is silently dropped from the iPod copy.
    private func willSync(_ entry: PlaylistEntry) -> Bool {
        let path = entry.resolvedURL(libraryRoot: libraryStore.libraryRoot).path
        let selected = libraryStore.selectedTrackPaths
        if selected.contains(path) { return true }
        // A .m3u written by another tool can carry the opposite Unicode
        // normalization for the same filename — macOS hands out NFD paths,
        // most other things write NFC.
        if selected.contains(path.precomposedStringWithCanonicalMapping) { return true }
        return selected.contains(path.decomposedStringWithCanonicalMapping)
    }

    private func unsyncedEntryCount(_ playlist: Playlist) -> Int {
        playlist.entries.reduce(0) { $0 + (willSync($1) ? 0 : 1) }
    }

    private func entryList(for playlist: Playlist) -> some View {
        List {
            ForEach(Array(playlist.entries.enumerated()), id: \.element.id) { _, entry in
                EntryRow(
                    entry: entry,
                    libraryRoot: libraryStore.libraryRoot,
                    willSync: willSync(entry)
                )
            }
            .onMove { source, destination in
                playlistStore.moveEntries(playlistID: playlist.id, from: source, to: destination)
            }
            .onDelete { offsets in
                playlistStore.removeEntries(playlistID: playlist.id, at: offsets)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handlePlaylistDrop(urls, playlistID: playlist.id)
            return true
        } isTargeted: { _ in }
    }

    private func emptyDropTarget(playlistID: UUID) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Drop tracks here")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            handlePlaylistDrop(urls, playlistID: playlistID)
            return true
        } isTargeted: { _ in }
    }

    // MARK: - Actions

    private func commitNewPlaylist() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            creating = false
            return
        }
        do {
            let playlist = try playlistStore.create(name: trimmed)
            selection = playlist.id
        } catch {
            self.error = error.localizedDescription
        }
        creating = false
        newName = ""
    }

    private func startRename(_ playlist: Playlist) {
        renamingID = playlist.id
        draftName = playlist.name
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        do {
            try playlistStore.rename(id: id, to: draftName)
        } catch {
            self.error = error.localizedDescription
        }
        renamingID = nil
        draftName = ""
    }

    /// Drops onto the playlist list itself: only used for importing external
    /// .m3u/.m3u8 files (a track URL with no destination playlist is ambiguous,
    /// so we ignore those here).
    private func handleListDrop(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "m3u" || ext == "m3u8" {
                do { _ = try playlistStore.importExternal(url) } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    /// Drops onto a specific playlist's entry list: audio files become entries;
    /// .m3u files are ignored here (use the left list to import).
    private func handlePlaylistDrop(_ urls: [URL], playlistID: UUID) {
        let audioURLs = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext != "m3u" && ext != "m3u8"
        }
        guard !audioURLs.isEmpty else { return }
        playlistStore.addEntries(
            playlistID: playlistID,
            fileURLs: audioURLs,
            libraryRoot: libraryStore.libraryRoot
        )
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let checkState: SelectionCheckState
    let isNew: Bool
    let isRenaming: Bool
    @Binding var draftName: String
    let onToggle: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TristateCheckbox(state: checkState, toggle: onToggle)
            Image(systemName: "music.note.list").foregroundStyle(.secondary)
            if isRenaming {
                TextField("Name", text: $draftName, onCommit: onCommitRename)
                    .textFieldStyle(.roundedBorder)
                    .onExitCommand(perform: onCancelRename)
            } else {
                Text(playlist.name)
                    .lineLimit(1)
                    .foregroundStyle(checkState == .on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if isNew {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Color.accentColor)
                        .help("Not on the iPod yet")
                }
                Spacer()
                Text("\(playlist.trackCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct EntryRow: View {
    let entry: PlaylistEntry
    let libraryRoot: URL?
    /// False when the entry's track isn't checked in the Music tab — the iPod
    /// copy of the playlist will skip it.
    let willSync: Bool

    private var resolved: URL { entry.resolvedURL(libraryRoot: libraryRoot) }
    private var exists: Bool { FileManager.default.fileExists(atPath: resolved.path) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: exists ? "music.note" : "exclamationmark.triangle")
                .foregroundStyle(exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .lineLimit(1)
                Text(entry.displayArtistAlbum)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(willSync || !exists ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer()
            if !exists {
                Text("Missing")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if !willSync {
                Text("Not selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Check this track in the Music tab for it to reach the iPod.")
            }
        }
        .help(entry.path)
    }
}

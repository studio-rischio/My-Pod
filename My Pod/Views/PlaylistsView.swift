import SwiftUI

/// Read-only view of the `.m3u` files in the playlist folder.
///
/// Editing was removed deliberately: the tab could create and rename playlists
/// but had no way to get tracks into one from the Music tab, so every path
/// through it ended at an empty playlist. Until that gap is filled, playlists
/// are authored wherever they already live — Finder, a text editor, another
/// music app — and My Pod's job is to show them and sync the checked ones.
///
/// That makes `Refresh` load-bearing rather than a convenience: it's the only
/// way a file edited outside the app reaches this list.
struct PlaylistsView: View {
    @Bindable var playlistStore: PlaylistStore
    @Bindable var libraryStore: MusicLibraryStore

    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            playlistList
                .frame(minWidth: 220, idealWidth: 260)
            detail
                .frame(minWidth: 360)
        }
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
                    Log.ui.info("user refreshed playlists")
                    playlistStore.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-read the playlist folder — use this after editing a .m3u file elsewhere")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if playlistStore.playlists.isEmpty {
                emptyFolderState
            } else {
                List(selection: $selection) {
                    ForEach(playlistStore.playlists) { playlist in
                        PlaylistRow(
                            playlist: playlist,
                            checkState: playlistStore.isSelected(playlist) ? .on : .off,
                            isNew: playlistStore.isNew(playlist),
                            onToggle: { playlistStore.toggleSelected(playlist) }
                        )
                        .tag(playlist.id)
                        .contextMenu {
                            Button(playlistStore.isSelected(playlist) ? "Don't Sync" : "Sync to iPod") {
                                playlistStore.toggleSelected(playlist)
                            }
                            Divider()
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([playlist.fileURL])
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

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

    private var emptyFolderState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No playlists")
                .font(.headline)
            Text("Put .m3u files in the playlist folder, then refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([playlistStore.directory])
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right: selected playlist contents

    @ViewBuilder
    private var detail: some View {
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

                // The per-playlist sync checkbox that used to live here was
                // redundant with the one on every row in the left list. The
                // warning beside it was not, and stays: it's the only thing
                // telling you that checking a playlist does not pull its tracks
                // onto the iPod.
                if playlistStore.isSelected(playlist), unsyncedEntryCount(playlist) > 0 {
                    HStack(spacing: 6) {
                        Label("\(unsyncedEntryCount(playlist)) of \(playlist.trackCount) entries won't sync", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .help("These entries point at tracks that aren't checked in the Music tab. Checking a playlist doesn't select its tracks — the iPod copy will skip them.")
                }

                Divider()
                    .padding(.top, 8)

                if playlist.entries.isEmpty {
                    emptyPlaylistState
                } else {
                    entryList(for: playlist)
                }

                Divider()

                HStack(spacing: 6) {
                    Text(playlist.fileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([playlist.fileURL])
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
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

    private var emptyPlaylistState: some View {
        VStack(spacing: 6) {
            Text("This playlist is empty")
                .foregroundStyle(.secondary)
            Text("Add tracks to the .m3u file, then refresh.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let checkState: SelectionCheckState
    let isNew: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TristateCheckbox(state: checkState, toggle: onToggle)
            Image(systemName: "music.note.list").foregroundStyle(.secondary)
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

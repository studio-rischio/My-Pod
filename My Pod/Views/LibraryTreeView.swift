import SwiftUI

/// Hand-rolled tree (no DisclosureGroup) so we can control click handling:
///   - plain click on a row selects it (replaces highlight)
///   - shift-click adds to highlight
///   - option-click removes from highlight
///   - the chevron on artist/album rows is the only way to expand/collapse
///   - the checkbox toggles iPod-sync selection (with bulk fan-out when the
///     clicked row is part of a multi-row highlight)
struct LibraryTreeView: View {
    @Bindable var store: MusicLibraryStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.library.artists) { artist in
                    ArtistRow(store: store, artist: artist)
                    if store.expandedArtists.contains(artist.name) {
                        ForEach(artist.albums) { album in
                            AlbumRow(store: store, album: album)
                            let albumKey = "\(album.artist)/\(album.name)"
                            if store.expandedAlbums.contains(albumKey) {
                                ForEach(album.tracks) { track in
                                    TrackRow(store: store, track: track)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(NSColor.textBackgroundColor))
        .onKeyPress(.escape) {
            if !store.highlightedRowIDs.isEmpty {
                store.clearHighlight()
                return .handled
            }
            return .ignored
        }
    }
}

// MARK: - Rows

private struct ArtistRow: View {
    @Bindable var store: MusicLibraryStore
    let artist: LibraryArtist

    var body: some View {
        let _ = store.selectedTrackPaths
        let _ = store.highlightedRowIDs
        let rowID = MusicLibraryStore.artistRowID(artist)
        let isHighlighted = store.highlightedRowIDs.contains(rowID)
        let isExpanded = store.expandedArtists.contains(artist.name)

        TreeRow(
            indentLevel: 0,
            chevron: TreeChevron(isExpanded: isExpanded) {
                if isExpanded { store.expandedArtists.remove(artist.name) }
                else { store.expandedArtists.insert(artist.name) }
            },
            checkbox: TristateCheckbox(state: store.state(for: artist)) {
                let next = store.state(for: artist) != .on
                if isHighlighted, store.highlightedRowIDs.count > 1 {
                    store.applyToHighlights(next)
                } else {
                    store.setArtistSelected(artist, next)
                }
            },
            highlighted: isHighlighted,
            isNew: store.newArtistNames.contains(artist.name),
            rowID: rowID,
            store: store
        ) {
            Image(systemName: "music.mic").foregroundStyle(.secondary)
            Text(artist.name).fontWeight(.medium)
            Spacer()
            Text("\(artist.trackCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct AlbumRow: View {
    @Bindable var store: MusicLibraryStore
    let album: LibraryAlbum

    var body: some View {
        let _ = store.selectedTrackPaths
        let _ = store.highlightedRowIDs
        let rowID = MusicLibraryStore.albumRowID(album)
        let isHighlighted = store.highlightedRowIDs.contains(rowID)
        let albumKey = "\(album.artist)/\(album.name)"
        let isExpanded = store.expandedAlbums.contains(albumKey)

        TreeRow(
            indentLevel: 1,
            chevron: TreeChevron(isExpanded: isExpanded) {
                if isExpanded { store.expandedAlbums.remove(albumKey) }
                else { store.expandedAlbums.insert(albumKey) }
            },
            checkbox: TristateCheckbox(state: store.state(for: album)) {
                let next = store.state(for: album) != .on
                if isHighlighted, store.highlightedRowIDs.count > 1 {
                    store.applyToHighlights(next)
                } else {
                    store.setAlbumSelected(album, next)
                }
            },
            highlighted: isHighlighted,
            isNew: store.newAlbumIDs.contains(album.id),
            rowID: rowID,
            store: store
        ) {
            Image(systemName: "square.stack").foregroundStyle(.secondary)
            Text(album.name)
            Spacer()
            if album.anyNeedsConversion {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .help("Contains tracks that need conversion")
            }
            Text(byteCount(album.sizeBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct TrackRow: View {
    @Bindable var store: MusicLibraryStore
    let track: LibraryTrack

    var body: some View {
        let _ = store.highlightedRowIDs
        let isOn = store.selectedTrackPaths.contains(track.url.path)
        let rowID = MusicLibraryStore.trackRowID(track)
        let isHighlighted = store.highlightedRowIDs.contains(rowID)

        TreeRow(
            indentLevel: 2,
            // Tracks have no children; render an invisible spacer the same
            // width as a chevron so columns line up across rows.
            chevron: nil,
            checkbox: TristateCheckbox(state: isOn ? .on : .off) {
                if isHighlighted, store.highlightedRowIDs.count > 1 {
                    store.applyToHighlights(!isOn)
                } else {
                    store.toggleTrack(track)
                }
            },
            highlighted: isHighlighted,
            isNew: store.newTrackPaths.contains(track.url.path),
            rowID: rowID,
            store: store,
            draggable: track.url
        ) {
            Text(track.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(track.fileExtension.uppercased())
                .font(.caption2)
                .foregroundStyle(track.needsConversion ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            Text(byteCount(track.sizeBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Generic row container

/// Shared chrome for every row in the tree. The chevron and checkbox both
/// live inside Buttons, so taps on those don't bubble out to the row-wide
/// gesture handlers below — only clicks on the label area drive selection.
private struct TreeRow<Label: View>: View {
    let indentLevel: Int
    let chevron: TreeChevron?
    let checkbox: TristateCheckbox
    let highlighted: Bool
    let isNew: Bool
    let rowID: String
    @Bindable var store: MusicLibraryStore
    var draggable: URL? = nil
    @ViewBuilder let label: () -> Label

    private static var indentStep: CGFloat { 18 }
    private static var chevronWidth: CGFloat { 14 }

    var body: some View {
        HStack(spacing: 8) {
            // New-music marker sits in its own gutter *outside* the indent, so
            // dots line up in a single column the way unread markers do in
            // Mail rather than stepping in with the tree depth.
            NewDot(isNew: isNew)

            // Indent + chevron (or matching spacer when leaf).
            Spacer().frame(width: CGFloat(indentLevel) * Self.indentStep)
            if let chevron {
                chevron
                    .frame(width: Self.chevronWidth)
            } else {
                Spacer().frame(width: Self.chevronWidth)
            }

            checkbox

            label()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.accentColor.opacity(0.20) : Color.clear)
        .contentShape(Rectangle())
        .modifier(DraggableModifier(url: draggable))
        // Modifier-aware taps come first so they win over plain tap below.
        // .modifiers(.shift) only fires when shift is held, etc., so plain
        // clicks fall through to the unmodified handler.
        .highPriorityGesture(
            TapGesture().modifiers(.shift).onEnded {
                store.addToHighlight(rowID)
            }
        )
        .highPriorityGesture(
            TapGesture().modifiers(.option).onEnded {
                store.removeFromHighlight(rowID)
            }
        )
        .onTapGesture {
            store.setHighlight(rowID)
        }
    }
}

/// Unread-style marker for library entries that aren't on the iPod yet. Always
/// occupies its slot so row content doesn't shift when the dot appears.
private struct NewDot: View {
    let isNew: Bool

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .opacity(isNew ? 1 : 0)
            .frame(width: 8)
            .accessibilityHidden(!isNew)
            .accessibilityLabel("New")
            .help(isNew ? "Not on the iPod yet" : "")
    }
}

private struct TreeChevron: View {
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeOut(duration: 0.12), value: isExpanded)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

/// `.draggable` only takes a value, not an optional. Apply it conditionally
/// so leaf-only `TrackRow` can pass a URL while artist/album rows skip it.
///
/// This outlived the playlist drop targets it was added for, and is kept on
/// purpose: with playlist editing gone, `.m3u` files are authored in other
/// apps, and dragging tracks out of here into one of them is now the workflow
/// rather than a side effect.
private struct DraggableModifier: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url {
            content.draggable(url)
        } else {
            content
        }
    }
}

private func byteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
}

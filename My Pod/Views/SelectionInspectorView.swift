import SwiftUI

/// Details for whatever is highlighted in the library tree.
///
/// Highlight, not checkboxes: this answers "what is this thing?", while the
/// panel above it answers "what will sync?". Clicking a row shows it,
/// shift-clicking adds to it, and with nothing clicked it falls back to the
/// library as a whole — so the panel is never blank.
struct SelectionInspectorView: View {
    @Bindable var store: MusicLibraryStore

    @State private var stats: SelectionStats?
    @State private var detail: TrackDetail?
    @State private var artwork: NSImage?
    @State private var covers: [AlbumCover] = []
    @State private var extraAlbums = 0
    @State private var loading = false

    /// One album's cover in the grid. `image` is nil once loading finished and
    /// nothing was found — distinct from "not loaded yet", which is simply an
    /// entry that hasn't appeared in the array.
    private struct AlbumCover: Identifiable, Equatable {
        let id: String
        let name: String
        let artist: String
        let image: NSImage?
    }

    /// Enough to recognise what's selected at a glance, not enough to become a
    /// scrolling list. Five plus the overflow tile lays out as two even rows.
    private static let maxCovers = 5
    private static let coverSide: CGFloat = 54

    private var items: [MusicLibraryStore.HighlightedItem] { store.highlightedItems }

    /// Changes whenever the highlight, the library, the device or the cache
    /// layout does — everything the numbers below depend on.
    private var reloadKey: String {
        let rows = store.highlightedRowIDs.sorted().joined(separator: "|")
        return "\(rows)#\(store.library.scannedAt.timeIntervalSince1970)#\(store.deviceSnapshot?.bytesByTrackKey.count ?? -1)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if loading {
                    ProgressView().controlSize(.small)
                } else if !store.highlightedRowIDs.isEmpty {
                    Button("Clear") { store.clearHighlight() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 148, maxHeight: 148)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    .padding(.vertical, 2)
            } else if showsArtworkSlot {
                noArtwork
            }

            if !covers.isEmpty { coverGrid }

            if let detail {
                trackRows(detail)
            } else if let stats {
                statRows(stats)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: reloadKey) { await reload() }
    }

    // MARK: - Header

    private var title: String {
        switch items.count {
        case 0: "Library"
        case 1:
            switch items[0] {
            case .artist(let a): a.name
            case .album(let a): a.name
            case .track(let t): t.title
            }
        default: "\(items.count) items selected"
        }
    }

    private var subtitle: String? {
        guard items.count == 1 else { return nil }
        switch items[0] {
        case .artist: return nil
        case .album(let a): return a.artist
        case .track(let t): return "\(t.artist) — \(t.album)"
        }
    }

    private var showsArtworkSlot: Bool {
        guard items.count == 1, !loading else { return false }
        switch items[0] {
        case .album, .track: return true
        case .artist: return false
        }
    }

    private var noArtwork: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.tertiary)
            Text("No cover art found")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help("A sync would leave this album without artwork on the iPod.")
    }

    // MARK: - Cover grid

    private var coverGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.coverSide), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(covers) { cover in
                Group {
                    if let image = cover.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle().fill(.quaternary.opacity(0.6))
                            Image(systemName: "music.note")
                                .foregroundStyle(.tertiary)
                                .imageScale(.small)
                        }
                    }
                }
                .frame(width: Self.coverSide, height: Self.coverSide)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
                .help(cover.image == nil
                      ? "\(cover.name) — \(cover.artist) (no cover art)"
                      : "\(cover.name) — \(cover.artist)")
            }

            if extraAlbums > 0 { overflowTile }
        }
        .padding(.bottom, 2)
    }

    /// Stands in for the albums the grid didn't draw, sized and shaped like a
    /// cover so the row stays even.
    private var overflowTile: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.6))
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .imageScale(.medium)
        }
        .frame(width: Self.coverSide, height: Self.coverSide)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .help("\(extraAlbums) more album\(extraAlbums == 1 ? "" : "s") not shown")
        .accessibilityLabel("\(extraAlbums) more albums not shown")
    }

    // MARK: - Track

    @ViewBuilder
    private func trackRows(_ d: TrackDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Format", d.track.fileExtension.uppercased())
            row("Size", byteCount(d.track.sizeBytes))
            if d.track.durationMS > 0 {
                row("Length", duration(d.track.durationMS))
            }
            if d.track.trackNumber > 0 {
                row("Track", "\(d.track.trackNumber)")
            }

            Divider().padding(.vertical, 2)

            if d.track.needsConversion {
                row("On iPod as", "AAC 256 kbps")
                row(d.convertedBytes == nil ? "Will be" : "Converted", byteCount(d.deliveredBytes))
                if d.convertedBytes == nil {
                    Text("Not converted yet — this size is an estimate.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                row("On iPod as", "Copied unchanged")
            }

            if let onIPod = d.isOnIPod {
                row("Status", onIPod ? "On the iPod" : "Not on the iPod yet")
            }
            row("Checked", d.isChecked ? "Yes" : "No")

            Divider().padding(.vertical, 2)

            pathRow("Source", d.track.url)
            if let converted = d.convertedURL {
                pathRow(
                    d.convertedBytes == nil ? "Converted file (not yet created)" : "Converted file",
                    converted,
                    dimmed: d.convertedBytes == nil
                )
            }
        }
    }

    // MARK: - Aggregate

    @ViewBuilder
    private func statRows(_ s: SelectionStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if s.artists > 0 { row("Artists", "\(s.artists)") }
            if s.albums > 0 { row("Albums", "\(s.albums)") }
            row("Tracks", "\(s.tracks)")
            row("Size on disk", byteCount(s.sourceBytes))
            row("Size on iPod", byteCount(s.deliveredBytes))

            if s.needConversion > 0 {
                Divider().padding(.vertical, 2)
                row("Need conversion", "\(s.needConversion)")
                row("Already converted", "\(s.converted)")
                if s.convertedBytes > 0 {
                    row("Cache size", byteCount(s.convertedBytes))
                }
                if s.pendingConversion > 0 {
                    Text("\(s.pendingConversion) still to convert. Sizes for those are estimates.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().padding(.vertical, 2)
            row("Checked for sync", "\(s.checked) of \(s.tracks)")
            if let onIPod = s.onIPod {
                row("On the iPod", "\(onIPod) of \(s.tracks)")
            }
        }
    }

    // MARK: - Rows

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func pathRow(_ label: String, _ url: URL, dimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Show in Finder")
                // A file that hasn't been created yet can't be revealed.
                .disabled(dimmed)
            }
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption2)
                .monospaced()
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Loading

    private func reload() async {
        loading = true
        defer { loading = false }
        artwork = nil
        detail = nil
        stats = nil
        covers = []
        extraAlbums = 0

        let conversion = ConversionService()
        let checked = store.selectedTrackPaths
        let iPodKeys = store.deviceSnapshot.map { Set($0.bytesByTrackKey.keys) }
        let current = items

        // One track: the detailed view, plus its album's cover.
        if current.count == 1, case let .track(track) = current[0] {
            detail = await SelectionInspector.detail(
                for: track, checkedPaths: checked, iPodKeys: iPodKeys, conversion: conversion
            )
            artwork = await SelectionInspector.artwork(
                albumDirectory: track.url.deletingLastPathComponent(),
                candidate: track.url,
                maxPixel: 512
            )
            return
        }

        // Everything else rolls up to counts. A bare highlight of nothing
        // describes the whole library, so the panel always says something.
        var tracks: [LibraryTrack] = []
        var artistNames: Set<String> = []
        var albumIDs: Set<String> = []

        if current.isEmpty {
            for artist in store.library.artists {
                artistNames.insert(artist.name)
                for album in artist.albums {
                    albumIDs.insert(album.id)
                    tracks.append(contentsOf: album.tracks)
                }
            }
        } else {
            for item in current {
                switch item {
                case .artist(let a):
                    artistNames.insert(a.name)
                    for album in a.albums {
                        albumIDs.insert(album.id)
                        tracks.append(contentsOf: album.tracks)
                    }
                case .album(let a):
                    artistNames.insert(a.artist)
                    albumIDs.insert(a.id)
                    tracks.append(contentsOf: a.tracks)
                case .track(let t):
                    artistNames.insert(t.artist)
                    albumIDs.insert(t.artist + "/" + t.album)
                    tracks.append(t)
                }
            }
        }

        // Highlighting an artist and one of its albums would otherwise count
        // that album's tracks twice.
        var seen: Set<URL> = []
        tracks = tracks.filter { seen.insert($0.url).inserted }

        stats = await SelectionInspector.stats(
            tracks: tracks,
            artists: artistNames.count,
            albums: albumIDs.count,
            checkedPaths: checked,
            iPodKeys: iPodKeys,
            conversion: conversion
        )

        // A single album still gets its cover, full size.
        if current.count == 1, case let .album(album) = current[0], let first = album.tracks.first {
            artwork = await SelectionInspector.artwork(
                albumDirectory: album.directory, candidate: first.url, maxPixel: 512
            )
            return
        }

        // Anything covering more than one album gets a grid of thumbnails.
        guard !current.isEmpty else { return }
        await loadCovers(albumsIn: current)
    }

    /// Load thumbnails one at a time, appending as they arrive.
    ///
    /// Sequential rather than concurrent on purpose: `ArtworkLocator` memoizes
    /// per album directory, and a task group would let several tasks miss the
    /// same entry and each run the expensive embedded-art extraction before any
    /// of them finished. Feeding them through in order means a repeat selection
    /// is served entirely from that memo.
    ///
    /// Appending as each lands lets the grid fill in rather than blocking on the
    /// slowest album, and `Task.isCancelled` ends the run the moment the
    /// highlight changes — `.task(id:)` cancels for us.
    private func loadCovers(albumsIn items: [MusicLibraryStore.HighlightedItem]) async {
        var albums: [LibraryAlbum] = []
        var seen: Set<String> = []
        for item in items {
            switch item {
            case .artist(let a): albums.append(contentsOf: a.albums)
            case .album(let a): albums.append(a)
            case .track: continue   // a lone track is handled above
            }
        }
        albums = albums.filter { seen.insert($0.id).inserted }
            .sorted { $0.artist == $1.artist
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }

        // No lower bound: an artist looks like an artist whether it holds one
        // album or twenty, and a single tile is still the answer to "what is
        // this?". Only a lone album or track selection takes the large-cover
        // path instead, and both return before reaching here.
        extraAlbums = max(0, albums.count - Self.maxCovers)

        for album in albums.prefix(Self.maxCovers) {
            if Task.isCancelled { return }
            guard let first = album.tracks.first else { continue }
            let image = await SelectionInspector.artwork(
                albumDirectory: album.directory, candidate: first.url, maxPixel: 128
            )
            if Task.isCancelled { return }
            covers.append(AlbumCover(id: album.id, name: album.name, artist: album.artist, image: image))
        }
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }

    private func duration(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

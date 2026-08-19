import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Set an album's `cover.jpg` from an image the user supplies.
///
/// Same shell as the sync and manual sheets — 540pt, header / content / footer —
/// because this is the third thing in the app that takes a choice and commits
/// it, and they should feel like one app rather than three.
///
/// Three ways in, one way out: whichever tab produced the image, it lands in the
/// same preview with the same crop/fit toggle and the same Save. The tabs differ
/// only in where the bytes came from.
///
/// It writes the file and stops there. Getting the art onto an iPod that already
/// holds the album is `ArtworkSync`'s job and happens at the next sync: pushing
/// from here would mean a `save()` on a device that might be mid-sync, and the
/// gain — seeing the cover a few minutes earlier — doesn't pay for that.
struct AlbumArtSheet: View {
    let album: LibraryAlbum
    /// Called with the written file so the inspector can drop its cached image.
    let onSaved: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case search, file, embedded
        var id: String { rawValue }
        var title: String {
            switch self {
            case .search: "Search"
            case .file: "File"
            case .embedded: "In the Files"
            }
        }
    }

    @State private var tab: Source = .search
    @State private var source: CGImage?
    /// The squared result, held rather than recomputed in `body` — squaring a
    /// 4000px source is not something to redo on every redraw.
    @State private var preview: CGImage?
    @State private var sourceLabel = ""
    @State private var fill: CoverArt.Fill = .crop
    @State private var isTargeted = false
    @State private var loading = false
    @State private var showOverwriteConfirm = false
    @State private var showImporter = false
    @State private var error: String?
    @State private var saved: SaveResult?

    // Search. Two fields rather than one box: the Cover Art Archive fallback
    // needs artist and album as separate terms to return anything useful, and
    // splitting them here is also what lets someone fix just the half that's
    // wrong — usually the album, when a folder is named after the deluxe
    // edition.
    @State private var artistQuery = ""
    @State private var albumQuery = ""
    @State private var results: [ArtworkSearchResult] = []
    @State private var searching = false
    @State private var searched = false

    // Embedded
    @State private var embedded: [EmbeddedArtworkCandidate] = []
    @State private var scanningFiles = false
    @State private var scannedFiles = false

    private struct SaveResult {
        let url: URL
        /// The image the folder was using before, now outranked by `cover.jpg`.
        let shadowed: URL?
        /// iPods told to expect this cover at their next sync.
        let queued: [String]
    }

    private var writable: Bool { CoverArt.isWritable(album.directory) }
    private var editing: Bool { source != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            loadFile(url)
        }
        .onAppear {
            artistQuery = album.artist
            albumQuery = album.name
        }
    }

    // MARK: - Shell

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Album Art").font(.headline)
                Text("\(album.name) — \(album.artist)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if loading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let saved {
            savedView(saved)
        } else if editing {
            editor
        } else {
            picker
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Source.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            switch tab {
            case .search: searchTab
            case .file: fileTab
            case .embedded: embeddedTab
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if editing, saved == nil {
                Button("Back") {
                    source = nil
                    preview = nil
                    error = nil
                }
            }
            Spacer()
            if saved != nil {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if CoverArt.existingCover(in: album.directory) != nil {
                        showOverwriteConfirm = true
                    } else {
                        save()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!editing || !writable)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Replace the existing cover.jpg?",
            isPresented: $showOverwriteConfirm,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(album.name)” already has a cover.jpg. The old file is overwritten and can't be recovered.")
        }
    }

    // MARK: - Search tab

    private var searchTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Artist", text: $artistQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                TextField("Album", text: $albumQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("Search") { runSearch() }
                    .disabled(searching || !hasQuery)
            }

            // Said plainly and in the open, because it's the only thing in the
            // app that goes online and this audience will want to know.
            Text("Searches Apple Music, then the Cover Art Archive. Nothing is sent until you press Search, and only the words in the box are sent.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if searching {
                centred { ProgressView("Searching…") }
            } else if let error {
                centred { warning(error) }
            } else if results.isEmpty {
                centred {
                    Text(searched ? "No covers found." : "Filled in from the folder. Edit either field if that's not what the album is really called.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                        ForEach(results) { result in
                            SearchTile(result: result) { choose(result) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - File tab

    private var fileTab: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [7, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
                .frame(height: 220)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("Drop an image here")
                            .font(.title3)
                        Text("From Finder, or straight out of a browser")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Choose File…") { showImporter = true }
                            .padding(.top, 4)
                    }
                }

            if !writable { warning(notWritableMessage) }
            if let error { warning(error) }
            Spacer(minLength: 0)
        }
        .padding(16)
        .onDrop(of: Self.acceptedTypes, isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            accept(provider)
            return true
        }
    }

    // MARK: - Embedded tab

    private var embeddedTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pictures already inside this album's audio files. Saving one writes it out as cover.jpg, where Finder and other music apps can see it too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if scanningFiles {
                centred { ProgressView("Reading \(album.tracks.count) file\(album.tracks.count == 1 ? "" : "s")…") }
            } else if embedded.isEmpty {
                centred {
                    Text(scannedFiles
                         ? "None of this album's files has a picture inside it."
                         : "Nothing read yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                        ForEach(embedded) { candidate in
                            EmbeddedTile(candidate: candidate) { choose(candidate) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .task(id: album.id) {
            guard !scannedFiles else { return }
            scanningFiles = true
            embedded = await EmbeddedArtwork.scan(album: album)
            scanningFiles = false
            scannedFiles = true
            Log.artwork.info("embedded scan: \(embedded.count) distinct image(s) in \(album.name)")
        }
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(spacing: 14) {
            // The preview is the squared result, not the source — the whole
            // point of the toggle is seeing what the crop does before it's
            // written, so showing the original would defeat it.
            Group {
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 260, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)

            Picker("", selection: $fill) {
                ForEach(CoverArt.Fill.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .onChange(of: fill) { _, _ in rebuildPreview() }

            Text(fill == .crop
                 ? "The edges are trimmed to make a square. Right for almost every cover."
                 : "The whole image is kept and the sides are padded. Right for a wide sleeve scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(sourceLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !writable { warning(notWritableMessage) }
            if let error { warning(error) }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func savedView(_ result: SaveResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Cover art saved", systemImage: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)

            Text("Written to \(result.url.lastPathComponent) in “\(album.name)”.")
                .font(.callout)

            Text(result.queued.isEmpty
                 ? "It'll go to your iPod the first time you sync one. Nothing is copied — only the cover changes."
                 : "Queued for \(result.queued.joined(separator: ", ")) — sent at the next sync. Nothing is copied; only the cover changes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let shadowed = result.shadowed {
                Divider()
                // Not deleted: a music app quietly removing files from a music
                // folder is worse than a duplicate sitting unused.
                Text("“\(shadowed.lastPathComponent)” is still in the folder and is no longer used — cover.jpg takes priority. Delete it yourself if you don't want it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bits

    private var notWritableMessage: String {
        "This album's folder can't be written to, so cover art can't be saved there. It's usually a read-only or network volume."
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Choosing

    private var hasQuery: Bool {
        !(artistQuery + albumQuery).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func runSearch() {
        guard hasQuery else { return }
        error = nil
        results = []
        searching = true
        let artist = artistQuery, name = albumQuery
        Task {
            do {
                let found = try await ArtworkSearch.search(artist: artist, album: name)
                results = found
                Log.artwork.info("artwork search for \"\(artist) — \(name)\": \(found.count) result(s)")
            } catch {
                self.error = error.localizedDescription
            }
            searching = false
            searched = true
        }
    }

    private func choose(_ result: ArtworkSearchResult) {
        error = nil
        loading = true
        Task {
            guard let data = await ArtworkSearch.fetch(result) else {
                error = "That cover couldn't be downloaded."
                loading = false
                return
            }
            finish(CoverArt.load(data: data), label: "\(result.title) — \(result.source)")
        }
    }

    private func choose(_ candidate: EmbeddedArtworkCandidate) {
        error = nil
        loading = true
        finish(
            CoverArt.load(data: candidate.data),
            label: "From \(candidate.trackCount) file\(candidate.trackCount == 1 ? "" : "s") in this album"
        )
    }

    // MARK: - Dropping and loading

    /// Ordered by preference. A browser drag usually offers several of these at
    /// once, and a file URL is worth more than a bitmap because it keeps the
    /// original encoding.
    private static let acceptedTypes: [UTType] = [.fileURL, .image, .png, .tiff, .url]

    private func accept(_ provider: NSItemProvider) {
        error = nil
        loading = true
        // A file URL is offered by Finder and by some browsers; taking it first
        // means reading the original bytes instead of a screen-resolution bitmap.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    guard let url, url.isFileURL else { finish(nil, label: ""); return }
                    loadFile(url)
                }
            }
            return
        }
        for type in [UTType.png, .tiff, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                Task { @MainActor in
                    guard let data else { finish(nil, label: ""); return }
                    finish(CoverArt.load(data: data), label: "Dropped image")
                }
            }
            return
        }
        // A remote URL — an <img> dragged out of a page. Fetching it is a
        // network request, made only because the user just dragged it here;
        // nothing fetches on its own.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    guard let url else { finish(nil, label: ""); return }
                    await loadRemote(url)
                }
            }
            return
        }
        finish(nil, label: "")
    }

    private func loadFile(_ url: URL) {
        loading = true
        finish(CoverArt.load(contentsOf: url), label: url.lastPathComponent)
    }

    private func loadRemote(_ url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            finish(CoverArt.load(data: data), label: url.lastPathComponent)
        } catch {
            self.error = "That image couldn't be downloaded: \(error.localizedDescription)"
            loading = false
        }
    }

    private func finish(_ image: CGImage?, label: String) {
        loading = false
        guard let image else {
            error = "That doesn't look like an image My Pod can read."
            return
        }
        source = image
        sourceLabel = "\(label) — \(image.width) × \(image.height)"
        // A square source has nothing to choose between, and crop is the no-op
        // there.
        fill = .crop
        rebuildPreview()
    }

    private func rebuildPreview() {
        preview = source.flatMap { CoverArt.square($0, fill: fill) }
    }

    // MARK: - Saving

    private func save() {
        guard let squared = preview else {
            error = "That image couldn't be squared."
            return
        }
        // Read before writing: afterwards `cover.jpg` is the top-priority file
        // and would report itself.
        let shadowed = CoverArt.shadowedImage(in: album.directory)
        do {
            let url = try CoverArt.write(squared, toAlbum: album.directory)
            // Belt as well as braces. The new file's modification date is
            // already newer than a device's baseline, which is what makes the
            // next sync pick it up — but only if that baseline was stamped
            // before now. An iPod connected for the first time *after* this save
            // gets its baseline stamped later than the file, and would miss it
            // forever. Queuing explicitly makes delivery independent of which
            // clock ran first.
            let queued = ArtworkSync.enqueueForNextSync(albumID: album.id, store: .shared)
            saved = SaveResult(url: url, shadowed: shadowed, queued: queued)
            onSaved(url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Tiles

/// One online result. Loads its own thumbnail so the grid fills in as the
/// images arrive rather than waiting for the slowest one.
private struct SearchTile: View {
    let result: ArtworkSearchResult
    let onPick: () -> Void

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    Rectangle().fill(.quaternary.opacity(0.6))
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if failed {
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }

                Text(result.title)
                    .font(.caption)
                    .lineLimit(1)
                Text(result.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text([result.source, result.sizeLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 132, alignment: .leading)
        }
        .buttonStyle(.plain)
        .task(id: result.id) {
            guard let data = await ArtworkSearch.thumbnail(result),
                  let decoded = CoverArt.load(data: data) else {
                failed = true
                return
            }
            image = decoded
        }
    }
}

/// One distinct picture found inside the album's files.
private struct EmbeddedTile: View {
    let candidate: EmbeddedArtworkCandidate
    let onPick: () -> Void

    @State private var image: CGImage?

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    Rectangle().fill(.quaternary.opacity(0.6))
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }

                Text("\(candidate.trackCount) file\(candidate.trackCount == 1 ? "" : "s")")
                    .font(.caption)
                Text(candidate.sizeLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 132, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(candidate.trackTitles.prefix(6).joined(separator: "\n")
              + (candidate.trackCount > 6 ? "\n…and \(candidate.trackCount - 6) more" : ""))
        .task(id: candidate.id) {
            image = CoverArt.load(data: candidate.data)
        }
    }
}

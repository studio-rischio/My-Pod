import Foundation

/// Walks a Plex-structured root (`Root/<Artist>/<Album>/<Track>`), groups files
/// into a `MusicLibrary`. Title and track number are parsed from filenames the
/// same way `ipod-sync.c` does it. `nonisolated` because scanning runs on a
/// detached background task — overrides the project-wide MainActor default.
nonisolated enum LibraryScanner {
    /// Takes no conversion ceiling. The scan records what each file *is*, and
    /// whether that's out of spec is decided per-iPod at the point of use — see
    /// `SourceFormat`. One scan therefore serves every connected device, and
    /// changing a quality setting no longer means walking the library again.
    static func scan(root: URL) async -> MusicLibrary {
        await Task.detached(priority: .userInitiated) {
            scanSync(root: root)
        }.value
    }

    private static func scanSync(root: URL) -> MusicLibrary {
        let fm = FileManager.default
        var artists: [LibraryArtist] = []
        var totalTracks = 0

        guard let artistDirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return MusicLibrary(root: root, artists: [], totalTracks: 0, scannedAt: Date())
        }

        for artistURL in artistDirs.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            guard isDirectory(artistURL), !shouldSkip(artistURL) else { continue }
            let artistName = artistURL.lastPathComponent

            guard let albumDirs = try? fm.contentsOfDirectory(
                at: artistURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            var albums: [LibraryAlbum] = []
            for albumURL in albumDirs.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                guard isDirectory(albumURL), !shouldSkip(albumURL) else { continue }
                let tracks = scanAlbum(albumURL: albumURL, artist: artistName)
                guard !tracks.isEmpty else { continue }
                albums.append(LibraryAlbum(
                    artist: artistName,
                    name: albumURL.lastPathComponent,
                    directory: albumURL,
                    createdAt: creationDate(albumURL),
                    tracks: tracks
                ))
                totalTracks += tracks.count
            }

            if !albums.isEmpty {
                artists.append(LibraryArtist(name: artistName, albums: albums))
            }
        }

        return MusicLibrary(root: root, artists: artists, totalTracks: totalTracks, scannedAt: Date())
    }

    private static func scanAlbum(albumURL: URL, artist: String) -> [LibraryTrack] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: albumURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let albumName = albumURL.lastPathComponent
        var tracks: [LibraryTrack] = []
        for fileURL in files {
            let ext = fileURL.pathExtension
            guard AudioFormat.canSync(ext) else { continue }

            let baseName = fileURL.deletingPathExtension().lastPathComponent
            let (trackNumber, title) = parseFilename(baseName)
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0

            // The extension can't see inside the container: a 24-bit/96 kHz
            // ALAC and a 256k AAC are both `.m4a`. Probe the ones that could
            // plausibly be out of spec, and reuse that single read for the
            // duration below rather than opening the file twice.
            let probe = AudioFormat.shouldProbe(ext) ? AudioProbe.read(fileURL) : nil
            var format = AudioFormat.sourceFormat(ext: ext, probe: probe)

            // FLAC and friends have no CoreAudio probe, so their rate, depth and
            // length come from the container header instead — one open() per
            // file, and only for files that convert at every ceiling anyway.
            // Natives that pass `alwaysConverts` were already covered by `probe`.
            if format.alwaysConverts, probe == nil {
                let flac = FLACHeader.streamInfo(of: fileURL)
                format.sampleRate = flac.sampleRate
                format.bitDepth = flac.bitDepth
                format.durationMS = flac.durationMS
            }

            // Logged at the strictest rung, which is the superset: anything that
            // converts under any ceiling converts under this one.
            if let probe, format.needsConversion(under: .aac44) {
                Log.library.debug("out of spec at 44.1 kHz AAC: \(fileURL.lastPathComponent) — \(probe.summary)")
            }

            tracks.append(LibraryTrack(
                id: fileURL,
                artist: artist,
                album: albumName,
                trackNumber: trackNumber,
                title: title,
                fileExtension: ext.lowercased(),
                sizeBytes: size,
                format: format
            ))
        }
        // Sort: by track number ascending (with 0/no-number after), then by name.
        tracks.sort { lhs, rhs in
            switch (lhs.trackNumber, rhs.trackNumber) {
            case (0, 0): return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case (0, _): return false
            case (_, 0): return true
            default:
                if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        return tracks
    }

    /// Mirrors the regex from ipod-sync.c:
    ///   `01 - Track Title`  → (1, "Track Title")
    ///   `01. Track Title`   → (1, "Track Title")
    ///   `01 Track Title`    → (1, "Track Title")
    ///   `Track Title`       → (0, "Track Title")
    static func parseFilename(_ base: String) -> (Int, String) {
        var i = base.startIndex
        // Read leading digits.
        var digits = ""
        while i < base.endIndex, base[i].isNumber {
            digits.append(base[i])
            i = base.index(after: i)
        }
        guard let n = Int(digits), !digits.isEmpty else {
            return (0, base)
        }
        // Skip a separator: optional "." or "-" surrounded by spaces, or a single space.
        var j = i
        while j < base.endIndex, base[j].isWhitespace { j = base.index(after: j) }
        if j < base.endIndex, "-.".contains(base[j]) {
            j = base.index(after: j)
            while j < base.endIndex, base[j].isWhitespace { j = base.index(after: j) }
        }
        let title = String(base[j...]).trimmingCharacters(in: .whitespaces)
        return (n, title.isEmpty ? base : title)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private static func shouldSkip(_ url: URL) -> Bool {
        let n = url.lastPathComponent
        return n.hasPrefix(".") || n.caseInsensitiveCompare("Playlists") == .orderedSame
    }
}

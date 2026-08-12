import Foundation

struct PlaylistEntry: Identifiable, Sendable, Hashable, Codable {
    let id: UUID
    /// Path written to the .m3u file. Conventionally relative to the library
    /// root (e.g. "Beck/Sea Change/01 The Golden Age.mp3"); may be absolute
    /// for tracks that live outside the library root.
    var path: String

    init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }

    var isAbsolute: Bool { path.hasPrefix("/") }

    func resolvedURL(libraryRoot: URL?) -> URL {
        if isAbsolute {
            return URL(fileURLWithPath: path)
        }
        if let libraryRoot {
            return libraryRoot.appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path)
    }

    /// Display title parsed from the path's filename.
    var displayTitle: String {
        let base = (path as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let (_, title) = LibraryScanner.parseFilename(stem)
        return title
    }

    var displayArtistAlbum: String {
        let components = path.split(separator: "/")
        guard components.count >= 3 else { return "" }
        return "\(components[components.count - 3]) — \(components[components.count - 2])"
    }
}

struct Playlist: Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var entries: [PlaylistEntry]
    /// Absolute file URL of the .m3u backing this playlist.
    var fileURL: URL

    var trackCount: Int { entries.count }

    /// Identity used to match a playlist across the three places it appears:
    /// the .m3u store, the sync selection set, and the iPod's own playlists.
    /// `Playlist.id` is a fresh UUID on every reload and the iPod stores no
    /// file path, so the name is the only thing all three share — the same
    /// bind that `TrackKey` solves for tracks.
    ///
    /// NFC because `.m3u` filenames come off macOS in NFD while
    /// `IPodDevice.createPlaylist` writes NFC; lowercased because
    /// `PlaylistStore` already treats names as case-insensitively unique.
    nonisolated static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    var nameKey: String { Self.nameKey(name) }
}

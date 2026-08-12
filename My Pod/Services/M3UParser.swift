import Foundation

/// Read and write M3U/M3U8 playlist files.
///
/// Format produced (matches `examples/Chill & Mellow.m3u`):
///
///     #EXTM3U
///     #PLAYLIST:My Playlist
///     Artist/Album/Track.mp3
///     ...
///
/// Lines starting with `#` are header/comment lines and are skipped on read,
/// except `#PLAYLIST:` which seeds the playlist name.
enum M3UParser {
    struct Parsed {
        var name: String?       // from #PLAYLIST:
        var entries: [PlaylistEntry]
    }

    static func parse(_ url: URL) throws -> Parsed {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var name: String?
        var entries: [PlaylistEntry] = []

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if let range = line.range(of: "#PLAYLIST:", options: .caseInsensitive),
                   range.lowerBound == line.startIndex {
                    name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            entries.append(PlaylistEntry(path: line))
        }
        return Parsed(name: name, entries: entries)
    }

    static func write(_ playlist: Playlist) throws {
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#PLAYLIST:\(playlist.name)")
        for entry in playlist.entries {
            lines.append(entry.path)
        }
        let text = lines.joined(separator: "\n") + "\n"
        try text.data(using: .utf8)?.write(to: playlist.fileURL, options: [.atomic])
    }
}

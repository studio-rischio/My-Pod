import Foundation

/// Identity used to match a library track against a track already on the iPod.
/// The iPod database doesn't store source file paths, so (artist, album, title)
/// is the only thing both sides share.
///
/// Shared by the sync planner (what to add/remove) and the Music tab's
/// "new music" highlight (what isn't on the device yet) so both agree on what
/// counts as the same track.
///
/// `nonisolated` — built from `IPodDevice` (an actor) and the detached library
/// scanner alike; overrides the project-wide MainActor default.
nonisolated struct TrackKey: Hashable, Sendable {
    let artist: String
    let album: String
    let title: String

    init(plan: PlannedTrack) {
        self.init(library: plan.library)
    }

    init(library: LibraryTrack) {
        self.init(artist: library.artist, album: library.album, title: library.title)
    }

    init(ipod: TrackInfo) {
        self.init(artist: ipod.artist, album: ipod.album, title: ipod.title)
    }

    init(artist: String, album: String, title: String) {
        self.artist = Self.normalize(artist)
        self.album = Self.normalize(album)
        self.title = Self.normalize(title)
    }

    private static func normalize(_ s: String) -> String {
        // NFC-normalize so a plan-side string parsed from a macOS filename
        // (NFD: "u" + combining diaeresis) compares equal to the iPod-side
        // string we wrote in NFC ("ü"). Without this, every accented title
        // would round-trip as a "not on iPod" miss, defeating the diff.
        s.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}

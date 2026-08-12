import Foundation

/// A user playlist as it currently exists on the iPod.
///
/// Read before a sync so the plan can say which playlists are being added,
/// removed, or changed — the sync itself still wipes and rewrites every user
/// playlist, so this is the only record of the "before" side.
///
/// `nonisolated` so it can be constructed from inside `IPodDevice` (an
/// `actor`) — overrides the project-wide MainActor default.
nonisolated struct DevicePlaylist: Sendable, Equatable, Identifiable {
    let id: UInt64
    var name: String
    /// Track IDs of the playlist's entries, in playlist order. Resolved to
    /// `TrackKey`s by the planner via the device's track list.
    var trackIDs: [UInt32]

    var trackCount: Int { trackIDs.count }

    init(_ raw: UnsafePointer<IPodPlaylistInfo>) {
        self.id = raw.pointee.id
        self.name = raw.pointee.name.flatMap { String(cString: $0) } ?? ""
        let count = Int(raw.pointee.track_count)
        if count > 0, let ids = raw.pointee.track_ids {
            self.trackIDs = Array(UnsafeBufferPointer(start: ids, count: count))
        } else {
            self.trackIDs = []
        }
    }

    init(id: UInt64, name: String, trackIDs: [UInt32]) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
    }
}

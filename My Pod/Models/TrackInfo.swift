import Foundation

// `nonisolated` so it can be constructed from inside `IPodDevice` (an
// `actor`) — overrides the project-wide MainActor default.
nonisolated struct TrackInfo: Sendable, Identifiable, Equatable {
    let id: UInt32
    var title: String
    var artist: String
    var album: String
    var genre: String
    var trackNumber: Int
    var discNumber: Int
    var durationMS: Int
    var sizeBytes: UInt32
    var bitrate: Int
    var year: Int

    init(_ raw: UnsafePointer<IPodTrackInfo>) {
        self.id = raw.pointee.id
        self.title = raw.pointee.title.flatMap { String(cString: $0) } ?? ""
        self.artist = raw.pointee.artist.flatMap { String(cString: $0) } ?? ""
        self.album = raw.pointee.album.flatMap { String(cString: $0) } ?? ""
        self.genre = raw.pointee.genre.flatMap { String(cString: $0) } ?? ""
        self.trackNumber = Int(raw.pointee.track_number)
        self.discNumber = Int(raw.pointee.disc_number)
        self.durationMS = Int(raw.pointee.duration_ms)
        self.sizeBytes = raw.pointee.size_bytes
        self.bitrate = Int(raw.pointee.bitrate)
        self.year = Int(raw.pointee.year)
    }
}

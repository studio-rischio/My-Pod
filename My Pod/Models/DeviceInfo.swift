import Foundation

// `nonisolated` so it can be constructed from inside `IPodDevice` (an
// `actor`) — overrides the project-wide MainActor default.
nonisolated struct DeviceInfo: Sendable, Equatable {
    var modelName: String
    var generation: String
    var capacityGB: Double
    var trackCount: Int
    var playlistCount: Int
    var uuid: String?
    var mountpoint: URL

    init(_ raw: UnsafePointer<IPodDeviceInfo>, mountpoint: URL) {
        self.modelName = raw.pointee.model_name.flatMap { String(cString: $0) } ?? "Unknown iPod"
        self.generation = raw.pointee.generation.flatMap { String(cString: $0) } ?? ""
        self.capacityGB = raw.pointee.capacity_gb
        self.trackCount = Int(raw.pointee.track_count)
        self.playlistCount = Int(raw.pointee.playlist_count)
        self.uuid = raw.pointee.uuid.flatMap { String(cString: $0) }
        self.mountpoint = mountpoint
    }

    var displayName: String {
        mountpoint.lastPathComponent
    }
}

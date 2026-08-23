import Foundation

// `nonisolated` so it can be constructed from inside `IPodDevice` (an
// `actor`) — overrides the project-wide MainActor default.
nonisolated struct DeviceInfo: Sendable, Equatable {
    var modelName: String
    var generation: String
    /// The model number libgpod matched, e.g. `A726`. `nil` when the device
    /// could not be identified — the normal state for an iPod restored by
    /// Finder or by Windows, neither of which writes `SysInfo`.
    var modelNumber: String?
    var capacityGB: Double
    var trackCount: Int
    var playlistCount: Int
    var uuid: String?
    var mountpoint: URL
    /// Whether libgpod will actually write cover art for this device.
    ///
    /// Not cosmetic, and not inferable from anything else here: it is the same
    /// question `itdb_write` asks before writing artwork, and when it is false
    /// covers are dropped in silence. False for two unrelated reasons —
    /// `modelNumber == nil` (fixable, see `DeviceIdentification`), or a model
    /// that predates artwork entirely (iPod 1G–4G, mini, shuffle).
    var supportsArtwork: Bool

    init(_ raw: UnsafePointer<IPodDeviceInfo>, mountpoint: URL) {
        self.modelName = raw.pointee.model_name.flatMap { String(cString: $0) } ?? "Unknown iPod"
        self.generation = raw.pointee.generation.flatMap { String(cString: $0) } ?? ""
        self.modelNumber = raw.pointee.model_number.flatMap { String(cString: $0) }
        self.capacityGB = raw.pointee.capacity_gb
        self.trackCount = Int(raw.pointee.track_count)
        self.playlistCount = Int(raw.pointee.playlist_count)
        self.uuid = raw.pointee.uuid.flatMap { String(cString: $0) }
        self.mountpoint = mountpoint
        self.supportsArtwork = raw.pointee.supports_artwork != 0
    }

    var displayName: String {
        mountpoint.lastPathComponent
    }

    /// Whether libgpod knows which iPod this is.
    var isIdentified: Bool { modelNumber != nil }

    /// The one case worth interrupting the user about: artwork will not sync,
    /// and it is fixable. An identified model that simply predates cover art
    /// is not this — nothing can be done and saying so would be noise.
    var needsIdentification: Bool { !isIdentified }
}

import AppKit
import Foundation
import Observation

/// Storage breakdown for the bottom bar (in bytes).
struct StorageBreakdown: Sendable, Equatable {
    var music: UInt64
    var other: UInt64
    var free: UInt64
    var capacity: UInt64

    static let empty = StorageBreakdown(music: 0, other: 0, free: 0, capacity: 0)

    var used: UInt64 { music &+ other }
}

/// What's currently on the connected iPod, in the terms the Music tab needs:
/// which tracks are present (so anything else in the library counts as "new")
/// and how much room is left. Rebuilt whenever the device is opened or
/// refreshed; `nil` in `IPodController` when no iPod is connected.
struct DeviceSnapshot: Sendable, Equatable {
    /// Bytes occupied per track key. Duplicate keys are summed, so removing
    /// everything under a key frees exactly this much.
    var bytesByTrackKey: [TrackKey: UInt64]
    var freeBytes: UInt64
    /// `Playlist.nameKey` of every user playlist on the device — the Playlists
    /// tab's equivalent of `bytesByTrackKey`: anything in the .m3u store
    /// that isn't in here is new.
    var playlistNameKeys: Set<String> = []
}

/// Top-level controller. Watches for an iPod, opens it, surfaces device info
/// and storage, and exposes the active actor for downstream features.
@MainActor
@Observable
final class IPodController {
    enum Status: Equatable {
        case noIPod
        case opening
        case ready
        case error(String)
    }

    private(set) var status: Status = .noIPod
    private(set) var deviceInfo: DeviceInfo?
    private(set) var storage: StorageBreakdown = .empty

    /// Track list + free space of the connected iPod. `nil` when no device is
    /// attached — the Music tab treats that as "new-ness unknown" and stays
    /// quiet rather than flagging the whole library.
    private(set) var snapshot: DeviceSnapshot?

    let watcher: VolumeWatcher
    private(set) var device: IPodDevice?

    init(watcher: VolumeWatcher? = nil) {
        let watcher = watcher ?? VolumeWatcher()
        self.watcher = watcher
        watcher.onChange = { [weak self] url in
            self?.handleConnectionChange(url: url)
        }
        // Pick up whatever was mounted before we wired the callback.
        handleConnectionChange(url: watcher.connectedIPod)
    }

    /// True when the mounted volume is materially larger (or smaller) than the
    /// capacity libgpod reports for this model.
    ///
    /// libgpod derives `DeviceInfo.capacityGB` from the model ID, so it's the
    /// size the iPod *shipped* with — it can't know the original drive has been
    /// swapped for a CF card, SD adapter or SSD, which is a common enough
    /// modification that a "20 GB" iPod happily holding 200 GB isn't unusual.
    /// Where the two disagree, the volume figure is the truthful one, and it's
    /// what every size calculation in the app already uses.
    ///
    /// The 25% threshold is deliberately loose: a stock drive's formatted
    /// capacity always lands a little under its marketing number, and that gap
    /// varies by model. Anything inside that band is treated as stock.
    var hasNonStockDrive: Bool {
        guard let info = deviceInfo, info.capacityGB > 0, storage.capacity > 0 else { return false }
        let stock = info.capacityGB * 1_000_000_000
        return abs(Double(storage.capacity) - stock) / stock > 0.25
    }

    /// Capacity to show the user: the mounted volume where we have it, falling
    /// back to the model's stock figure before the volume has been read.
    var effectiveCapacityBytes: UInt64 {
        if storage.capacity > 0 { return storage.capacity }
        guard let info = deviceInfo, info.capacityGB > 0 else { return 0 }
        return UInt64(info.capacityGB * 1_000_000_000)
    }

    private func handleConnectionChange(url: URL?) {
        guard let url else {
            Log.device.info("iPod disconnected")
            unload()
            return
        }
        if device?.mountpoint == url, status == .ready {
            return
        }
        Log.device.info("iPod connected at \(url.path)")
        load(url: url)
    }

    private func unload() {
        let device = self.device
        self.device = nil
        self.deviceInfo = nil
        self.storage = .empty
        self.snapshot = nil
        self.status = .noIPod
        Task { await device?.close() }
    }

    private func load(url: URL) {
        status = .opening
        let device = IPodDevice(mountpoint: url)
        self.device = device
        Task { [weak self] in
            await self?.openAndRefresh(device: device, url: url)
        }
    }

    private func openAndRefresh(device: IPodDevice, url: URL) async {
        do {
            try await device.open()
        } catch {
            Log.device.error("open failed at \(url.path): \(error.localizedDescription)")
            self.status = .error(error.localizedDescription)
            return
        }
        guard self.device === device else { return }   // raced with a disconnect
        let info = await device.deviceInfo()
        let musicBytes = await device.totalMusicBytes()
        let tracks = await device.tracks()
        let devicePlaylists = await device.userPlaylists()
        let breakdown = Self.computeStorage(volume: url, music: musicBytes)
        guard self.device === device else { return }
        self.deviceInfo = info
        self.storage = breakdown
        self.snapshot = DeviceSnapshot(
            bytesByTrackKey: Dictionary(
                tracks.map { (TrackKey(ipod: $0), UInt64($0.sizeBytes)) },
                uniquingKeysWith: { $0 &+ $1 }
            ),
            freeBytes: breakdown.free,
            playlistNameKeys: Set(devicePlaylists.map { Playlist.nameKey($0.name) })
        )
        self.status = .ready
        if let info {
            Log.device.info("iPod ready: \(info.displayName) (\(info.modelName)), \(info.trackCount) tracks, \(info.playlistCount) playlists")
        }
    }

    /// Compute Music / Other / Free from volume free space and the music bytes.
    private static func computeStorage(volume: URL, music: UInt64) -> StorageBreakdown {
        do {
            let values = try volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let capacity = UInt64(values.volumeTotalCapacity ?? 0)
            let free = UInt64(values.volumeAvailableCapacity ?? 0)
            let used = capacity > free ? capacity - free : 0
            let other = used > music ? used - music : 0
            return StorageBreakdown(music: music, other: other, free: free, capacity: capacity)
        } catch {
            return StorageBreakdown(music: music, other: 0, free: 0, capacity: 0)
        }
    }

    func refresh() {
        guard let device, let url = watcher.connectedIPod else { return }
        Task { [weak self] in
            await self?.openAndRefresh(device: device, url: url)
        }
    }

    // MARK: - Reset

    /// Close the iPod database and ask Disk Arbitration to unmount the
    /// volume. The `VolumeWatcher`'s didUnmount callback will then fire and
    /// drive the controller back to `.noIPod` via `handleConnectionChange`.
    func eject() {
        guard let oldDevice = device, let url = watcher.connectedIPod else { return }
        Log.device.info("user requested: eject \(url.path)")
        // Tear down our in-memory state up-front so the UI immediately
        // reflects the in-flight eject. If the unmount fails we restore the
        // error state below.
        self.device = nil
        self.deviceInfo = nil
        self.storage = .empty
        self.snapshot = nil
        self.status = .opening
        Task { [weak self] in
            await oldDevice.close()
            do {
                // NSWorkspace.unmountAndEjectDevice is synchronous + throwing
                // — no async work happens inside, so no `await` is needed.
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                Log.device.info("eject succeeded")
                // VolumeWatcher's didUnmount will clear status to .noIPod.
            } catch {
                Log.device.error("eject failed: \(error.localizedDescription)")
                await MainActor.run {
                    self?.status = .error("Eject failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func fullReset() {
        Log.device.info("user requested: reset iPod (wipe music + artwork + database)")
        runReset(label: "Resetting iPod…") { url in
            try IPodReset.fullReset(at: url)
        }
    }

    private func runReset(label: String, op: @escaping @Sendable (URL) throws -> Void) {
        guard let url = watcher.connectedIPod else { return }
        let oldDevice = device
        device = nil
        deviceInfo = nil
        storage = .empty
        snapshot = nil
        status = .opening
        Task { [weak self] in
            await oldDevice?.close()
            // The C reset calls do file I/O on the iPod volume — push them off
            // main actor.
            let outcome: Result<Void, Error> = await Task.detached {
                do { try op(url); return .success(()) }
                catch { return .failure(error) }
            }.value
            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .success:
                    Log.device.info("reset succeeded; reopening iPod")
                    self.load(url: url)
                case .failure(let error):
                    Log.device.error("reset failed: \(error.localizedDescription)")
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }
}

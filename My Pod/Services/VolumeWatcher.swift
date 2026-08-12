import AppKit
import Observation

/// Watches mounted volumes for an iPod (a volume containing `iPod_Control/`).
/// Single-iPod model — `connectedIPod` reflects whichever iPod is currently
/// connected, or nil. UI observes via @Observable; the controller is also
/// notified through the `onChange` callback so it can act eagerly.
@MainActor
@Observable
final class VolumeWatcher {
    private(set) var connectedIPod: URL?

    /// Optional sink for change events — set by the owner.
    @ObservationIgnored
    var onChange: ((URL?) -> Void)?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleMount(note) }
        }
        nc.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleUnmount(note) }
        }
        rescan()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func handleMount(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        if isIPod(url) {
            Log.device.debug("volume mounted (iPod): \(url.path)")
            update(connectedIPod: url)
        } else {
            Log.device.debug("volume mounted (not iPod): \(url.path)")
        }
    }

    private func handleUnmount(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        if connectedIPod == url {
            Log.device.debug("volume unmounted (iPod): \(url.path)")
            update(connectedIPod: nil)
        }
    }

    func rescan() {
        let fm = FileManager.default
        guard let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) else { return }
        update(connectedIPod: volumes.first(where: isIPod))
    }

    private func update(connectedIPod url: URL?) {
        guard connectedIPod != url else { return }
        connectedIPod = url
        onChange?(url)
    }

    private func isIPod(_ volume: URL) -> Bool {
        let control = volume.appendingPathComponent("iPod_Control", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: control.path, isDirectory: &isDir) && isDir.boolValue
    }
}

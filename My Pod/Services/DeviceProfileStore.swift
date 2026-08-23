import Foundation
import Observation

/// Owns every iPod My Pod has seen, and which one's settings are currently in
/// force.
///
/// Shared rather than injected because Settings is a separate `Settings {}`
/// scene with no reference to the main window's state — it already reads
/// `MyPod.libraryRoot` straight out of UserDefaults for that reason — and there
/// is genuinely one set of iPods per install. `DockProgressTracker.shared` sets
/// the same precedent.
@MainActor
@Observable
final class DeviceProfileStore {
    static let shared = DeviceProfileStore()

    /// Known devices, newest-seen first. Never includes the default profile.
    private(set) var devices: [DeviceProfile] = []

    /// Whose settings are in force. The default profile whenever no iPod is
    /// connected — the Music and Playlists tabs always have exactly one
    /// selection to edit, and the header says which.
    private(set) var active: DeviceProfile = .defaultProfile

    /// Every ceiling something is set to. Drives cache collection: anything not
    /// in here has no consumer and its converted files are deleted.
    var ceilingsInUse: Set<ConversionCeiling> {
        var out: Set<ConversionCeiling> = [ConversionCeiling.current]
        for device in devices { out.insert(device.ceiling) }
        return out
    }

    private let defaults = UserDefaults.standard
    private let devicesKey = "MyPod.deviceProfiles"

    private init() {
        load()
    }

    // MARK: - Connection

    /// Point the store at whichever iPod is now connected, or at the default
    /// profile when none is.
    ///
    /// Creating a profile on first sight seeds it from the default — same
    /// ceiling, and (via `MusicLibraryStore`/`PlaylistStore`) a copy of the
    /// default's selection. So plugging in a second iPod starts from what the
    /// first one syncs rather than from nothing.
    func deviceChanged(info: DeviceInfo?, capacityBytes: UInt64) {
        guard let info else {
            if !active.isDefault { Log.device.info("profile: no iPod — using default settings") }
            active = .defaultProfile
            return
        }

        let candidate = DeviceIdentity.identifiers(for: info, capacityBytes: capacityBytes)
        var profile: DeviceProfile
        if let index = devices.firstIndex(where: {
            DeviceIdentity.matches(candidate: candidate, existing: $0.identifiers)
        }) {
            profile = devices[index]
            devices.remove(at: index)
            Log.device.info("profile: recognized \"\(profile.displayName)\" — \(profile.ceiling.rawValue)")
        } else {
            profile = DeviceProfile(
                key: UUID(),
                identifiers: [],
                displayName: info.displayName,
                modelName: info.modelName,
                ceiling: ConversionCeiling.current,
                lastSeen: Date()
            )
            seedFromDefault(profile)
            Log.device.info("profile: first sight of \"\(info.displayName)\" — starting from the default settings")
        }

        // Union rather than replace, so a device that gains or loses an
        // identifier tier stays attached to the profile it already had.
        profile.identifiers.formUnion(candidate)
        profile.displayName = info.displayName
        profile.modelName = info.modelName
        profile.lastSeen = Date()
        devices.insert(profile, at: 0)
        active = profile
        // Both the migration for profiles written before artwork pushing
        // existed and the starting point for a newly-seen iPod: without a
        // baseline every album's cover looks newer than the device, and the
        // first sync after upgrading would re-push artwork for the whole
        // library.
        ArtworkSync.establishBaseline(for: profile)
        reconcileArtworkCapability(profile, supportsArtwork: info.supportsArtwork)
        save()
    }

    /// Notice when an iPod gains the ability to receive artwork, and make the
    /// next sync resend it all.
    ///
    /// Tracked per profile because the transition is invisible otherwise: a
    /// device the app couldn't identify took no covers at all, and everything
    /// synced to it in that state is `unchanged` as far as the sync diff is
    /// concerned. Identifying it has to reach backwards or the fix only helps
    /// music the user hasn't synced yet.
    ///
    /// Three states, not two, and the difference is load-bearing. **Unset**
    /// means a profile written before this existed — record what we see and
    /// change nothing, because assuming "was incapable" would re-push the whole
    /// library on the first launch after upgrading, for every user. Only a
    /// recorded `false` turning into `true` is a real transition.
    private func reconcileArtworkCapability(_ profile: DeviceProfile, supportsArtwork: Bool) {
        let key = profile.storageKey("artworkCapable")
        let previous = defaults.object(forKey: key) as? Bool
        if supportsArtwork, previous == false {
            ArtworkSync.resendEverything(to: profile, reason: "this iPod could not take artwork before and can now")
        }
        defaults.set(supportsArtwork, forKey: key)
    }

    /// Copy the default profile's selection into a brand-new device profile.
    ///
    /// Done here rather than in the two stores because this is the only place
    /// that knows a profile is new. The stores expose the key-level copy.
    private func seedFromDefault(_ profile: DeviceProfile) {
        MusicLibraryStore.copySelection(from: .defaultProfile, to: profile)
        PlaylistStore.copySelection(from: .defaultProfile, to: profile)
    }

    // MARK: - Editing

    /// Change a profile's quality ceiling, and collect whatever that orphans.
    func setCeiling(_ ceiling: ConversionCeiling, for key: UUID, libraryRoot: URL?) {
        if key == DeviceProfile.defaultKey {
            // The default profile's ceiling *is* `ConversionCeiling.current` —
            // one value, one meaning: what's used with no iPod attached, and
            // what a newly-seen iPod starts at.
            ConversionCeiling.setCurrent(ceiling)
            if active.isDefault { active.ceiling = ceiling }
        } else {
            guard let index = devices.firstIndex(where: { $0.key == key }) else { return }
            guard devices[index].ceiling != ceiling else { return }
            devices[index].ceiling = ceiling
            if active.key == key { active.ceiling = ceiling }
            save()
            Log.device.info("profile \"\(self.devices[index].displayName)\": quality \(ceiling.rawValue)")
        }
        collectUnusedCaches(libraryRoot: libraryRoot)
    }

    /// Switch an iPod between mirroring the library and being managed by hand.
    ///
    /// Deliberately not offered for the default profile: it's the settings used
    /// when *no* iPod is attached, and manual management is meaningless without
    /// a device to manage.
    ///
    /// Turning it **off** is the destructive direction — the next sync removes
    /// everything on the device that isn't in this profile's selection. The
    /// caller is responsible for warning first, which is the whole reason this
    /// is a mode switch rather than a silent rule: an explicit flip is a moment
    /// you can attach a warning to, where sync time is not.
    func setManageManually(_ manual: Bool, for key: UUID) {
        guard key != DeviceProfile.defaultKey,
              let index = devices.firstIndex(where: { $0.key == key }),
              devices[index].manageManually != manual else { return }
        devices[index].manageManually = manual
        if active.key == key { active.manageManually = manual }
        save()
        let name = devices[index].displayName
        Log.device.info("profile \(name): \(manual ? "managed by hand" : "mirrors the library")")
    }

    /// Forget a device: its profile, and every per-device set stored under it.
    func forget(_ key: UUID, libraryRoot: URL?) {
        guard key != DeviceProfile.defaultKey,
              let index = devices.firstIndex(where: { $0.key == key }) else { return }
        let profile = devices[index]
        devices.remove(at: index)
        MusicLibraryStore.forgetSelection(for: profile)
        PlaylistStore.forgetSelection(for: profile)
        ArtworkSync.forget(profile)
        if active.key == key { active = .defaultProfile }
        save()
        Log.device.info("profile forgotten: \"\(profile.displayName)\"")
        collectUnusedCaches(libraryRoot: libraryRoot)
    }

    /// Delete converted files for quality settings nothing is set to.
    ///
    /// Called at launch and after any change to a profile. The consequence worth
    /// knowing: switching a device from one setting to another and back
    /// re-encodes, because the first setting's cache is collected the moment
    /// nothing references it. That's the deliberate trade — bounded, predictable
    /// disk use over a free undo.
    func collectUnusedCaches(libraryRoot: URL?) {
        let inUse = ceilingsInUse
        Task.detached(priority: .utility) {
            CacheInventory.collectUnused(inUse: inUse, libraryRoot: libraryRoot)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: devicesKey) else { return }
        do {
            // Defensive: the default profile is synthesized, never stored, and
            // its selection keys belong to it alone.
            devices = try JSONDecoder().decode([DeviceProfile].self, from: data)
                .filter { !$0.isDefault }
            Log.device.info("loaded \(self.devices.count) iPod profile(s)")
        } catch {
            // Loud, because the quiet version is a disaster: every iPod's
            // quality setting and selection silently reverts to the default and
            // the next connect looks like a brand-new device. A field added to
            // `DeviceProfile` without a `decodeIfPresent` fallback lands exactly
            // here — the synthesized decoder throws on a missing key even when
            // the property has a default value.
            Log.device.error("couldn't read stored iPod profiles — they will be recreated from defaults: \(error)")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: devicesKey)
    }
}

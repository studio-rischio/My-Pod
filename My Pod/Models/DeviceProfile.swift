import Foundation

/// Per-iPod settings and sync selection.
///
/// Everything here is a property of *which device you are filling*, not of the
/// app: a modded 256 GB classic wants lossless and the whole library, an 8 GB
/// nano wants AAC and a fraction of it. Sharing one setting between them means
/// re-choosing on every swap.
///
/// The bulky parts — the track and playlist selections — deliberately do **not**
/// live in this struct. They're thousands of paths rewritten on every checkbox
/// click, and holding them here would mean re-encoding every device's state to
/// save one. They live under keys namespaced by `key` instead; see
/// `storageKey(_:)`.
nonisolated struct DeviceProfile: Codable, Sendable, Equatable, Identifiable {
    /// Stable and internal. Never changes, even when the device's *identity*
    /// does — so a reformatted iPod that comes back with a new volume UUID
    /// keeps its selection, and the namespaced storage keys below never move.
    let key: UUID
    /// Every identifier this device has ever presented. Matching is on any of
    /// them; see `DeviceIdentity`.
    var identifiers: Set<String>
    /// Volume name at last connect. Purely for the UI.
    var displayName: String
    var modelName: String
    var ceiling: ConversionCeiling
    var lastSeen: Date

    /// Whether this iPod is managed by hand rather than mirrored from the
    /// library.
    ///
    /// The two are mutually exclusive, not composable: a mirror has an opinion
    /// about what the whole device should hold, and manual management says the
    /// device owns itself. So this doesn't soften the sync — it decides which
    /// tabs exist at all. See `MainTabView`.
    var manageManually: Bool = false

    var id: UUID { key }

    // MARK: - Decoding

    /// Written by hand because the synthesized decoder **throws** on a missing
    /// key even when the property has a default — verified, not assumed. Profiles
    /// written before `manageManually` existed have no such key, and
    /// `DeviceProfileStore.load` decodes with `try?`, so the synthesized version
    /// would swallow the error and silently reset every iPod's quality setting
    /// and selection. Any field added here later needs the same treatment.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(UUID.self, forKey: .key)
        identifiers = try c.decode(Set<String>.self, forKey: .identifiers)
        displayName = try c.decode(String.self, forKey: .displayName)
        modelName = try c.decode(String.self, forKey: .modelName)
        ceiling = try c.decode(ConversionCeiling.self, forKey: .ceiling)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        manageManually = try c.decodeIfPresent(Bool.self, forKey: .manageManually) ?? false
    }

    init(
        key: UUID,
        identifiers: Set<String>,
        displayName: String,
        modelName: String,
        ceiling: ConversionCeiling,
        lastSeen: Date,
        manageManually: Bool = false
    ) {
        self.key = key
        self.identifiers = identifiers
        self.displayName = displayName
        self.modelName = modelName
        self.ceiling = ceiling
        self.lastSeen = lastSeen
        self.manageManually = manageManually
    }

    /// The profile in use when no iPod is connected, and the template every
    /// newly-seen device is seeded from.
    ///
    /// It's a real profile rather than a special case so the Music and Playlists
    /// tabs always have exactly one selection to edit. Its ceiling is stored in
    /// `ConversionCeiling.current` rather than in the profiles blob, which keeps
    /// 1.6's behaviour — and its 1.5 migration — untouched for anyone with a
    /// single iPod.
    static let defaultKey = UUID(uuidString: "00000000-0000-0000-0000-00004D794D50")!

    var isDefault: Bool { key == Self.defaultKey }

    static var defaultProfile: DeviceProfile {
        DeviceProfile(
            key: defaultKey,
            identifiers: [],
            displayName: "Default",
            modelName: "",
            ceiling: .current,
            lastSeen: .distantPast
        )
    }

    /// UserDefaults key for one of this profile's per-device sets.
    func storageKey(_ name: String) -> String {
        "MyPod.profile.\(key.uuidString).\(name)"
    }
}

/// How an iPod is recognized across connections.
///
/// Three tiers, strongest first, each namespaced so they can't be confused for
/// one another. A device is matched on *any* identifier it has ever presented,
/// so gaining or losing a tier doesn't orphan its profile.
nonisolated enum DeviceIdentity {
    /// libgpod's `FirewireGuid`, out of `iPod_Control/Device/SysInfo`.
    ///
    /// Survives My Pod's own reset — `ipod_full_reset` clears only
    /// `iPod_Control/Music`, `iPod_Control/Artwork` and the iTunesDB files — but
    /// not a Disk Utility reformat. Absent on an iPod iTunes has never written
    /// `SysInfoExtended` to.
    static let firewirePrefix = "fw:"
    /// The volume's own UUID. Survives remounting and renaming; changes on
    /// reformat.
    static let volumePrefix = "vol:"
    /// Volume name plus capacity. Survives everything, and is the one tier that
    /// can genuinely collide — two identical stock nanos both called "iPod".
    static let namePrefix = "name:"

    /// Identifiers for the connected device, strongest first.
    static func identifiers(for info: DeviceInfo, capacityBytes: UInt64) -> [String] {
        var out: [String] = []
        if let uuid = info.uuid?.trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty {
            out.append(firewirePrefix + uuid)
        }
        if let volume = try? info.mountpoint.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
            out.append(volumePrefix + volume)
        }
        // Capacity is in the key so at least the size has to agree before two
        // same-named iPods are treated as one.
        out.append("\(namePrefix)\(info.mountpoint.lastPathComponent)-\(capacityBytes)")
        return out
    }

    /// Whether `candidate` may be matched against a profile holding
    /// `existing` identifiers.
    ///
    /// The `name:` tier is weak, so it only matches profiles that have **never**
    /// carried a `fw:` identifier. `SysInfo` survives My Pod's reset, so a device
    /// that once reported a FirewireGuid will normally keep reporting one; if
    /// this device has none and the profile does, they're more likely two
    /// different iPods than one reformatted one.
    ///
    /// The case this gets wrong on purpose: an iPod reformatted in Disk Utility
    /// (which *does* wipe `SysInfo`) gets a fresh profile instead of
    /// re-attaching. That's recoverable by forgetting the stale one. The
    /// alternative failure — silently merging two different iPods into one
    /// profile — corrupts both selections and isn't.
    static func matches(candidate: [String], existing: Set<String>) -> Bool {
        for identifier in candidate where !identifier.hasPrefix(namePrefix) {
            if existing.contains(identifier) { return true }
        }
        guard !existing.contains(where: { $0.hasPrefix(firewirePrefix) }) else { return false }
        return candidate.contains { $0.hasPrefix(namePrefix) && existing.contains($0) }
    }
}

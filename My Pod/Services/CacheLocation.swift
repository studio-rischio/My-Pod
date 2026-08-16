import CryptoKit
import Foundation

/// Where converted `.m4a` files are kept.
///
/// The two options trade the same thing in opposite directions. Beside the
/// music, the cache *is* keyed by the file's location, so it survives renaming
/// a folder, reorganising the library, or copying an album to another Mac — the
/// key moves with the file. In Application Support it's keyed by a hash of the
/// absolute path, so moving the library orphans everything and it all re-encodes
/// — but the music folders are never written to at all, which matters for a
/// read-only or network library, and for anyone syncing their library through
/// Dropbox or iCloud who would otherwise replicate the cache with it.
///
/// Application Support is the default because leaving the user's library
/// untouched is the safer surprise. Existing installs keep `.mypod` — see
/// `resolvedDefault`.
nonisolated enum CacheLocation: String, CaseIterable, Sendable {
    case applicationSupport
    case besideMusic

    // MARK: - Preference

    private static let key = "MyPod.cacheLocation"
    private static let libraryRootKey = "MyPod.libraryRoot"

    /// Posted when the location changes, so anything holding derived state
    /// about what's cached can throw it away.
    static let didChange = Notification.Name("MyPod.cacheLocationChanged")

    static var current: CacheLocation {
        if let raw = UserDefaults.standard.string(forKey: key),
           let value = CacheLocation(rawValue: raw) {
            return value
        }
        let resolved = resolvedDefault
        // Write it down rather than re-deriving: `resolvedDefault` depends on
        // whether a library root exists, and that changes the moment the user
        // picks one. Without this, a fresh install would silently switch from
        // Application Support to `.mypod` as soon as a library was chosen.
        UserDefaults.standard.set(resolved.rawValue, forKey: key)
        return resolved
    }

    static func setCurrent(_ location: CacheLocation) {
        guard location != current else { return }
        UserDefaults.standard.set(location.rawValue, forKey: key)
        Log.convert.info("cache location: \(location.rawValue)")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Fresh installs get Application Support. An install that already has a
    /// library root is an upgrade, and switching it would strand every
    /// conversion it has already made — potentially hours of transcoding — so
    /// it keeps the behaviour it was built with.
    private static var resolvedDefault: CacheLocation {
        UserDefaults.standard.string(forKey: libraryRootKey) == nil
            ? .applicationSupport
            : .besideMusic
    }

    // MARK: - Paths

    /// `~/Library/Application Support/My Pod/Converted`.
    static var appSupportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("My Pod", isDirectory: true)
            .appendingPathComponent("Converted", isDirectory: true)
    }

    /// The cache version lives in the path rather than in a marker file.
    ///
    /// A marker can't distinguish "this directory has been upgraded" from "this
    /// *file* has been re-encoded": the first track converted after a version
    /// bump rewrites the marker, and every other file in the same directory then
    /// looks current while still holding old output. Encoding the version in the
    /// path makes a bump a different location, so a stale file is unreachable
    /// rather than merely mislabelled.
    private static func versionedRoot(rate: Int) -> URL {
        appSupportRoot.appendingPathComponent(
            "v\(ConversionService.cacheVersion)\(suffix(forRate: rate))",
            isDirectory: true
        )
    }

    /// Distinguishes output encoded at different sample rates.
    ///
    /// Keyed on the rate the encoder actually targeted, not on the conversion
    /// profile, and empty at 44.1 kHz. Both details matter. Empty at 44.1 keeps
    /// every file converted before this setting existed exactly where it was, so
    /// upgrading re-encodes nothing. Keying on the rate rather than the profile
    /// means a 44.1 kHz FLAC lands in the same place under every profile — its
    /// output is byte-identical either way — so switching to "Allow 48 kHz" to
    /// spare a handful of hi-res files doesn't re-transcode the whole library.
    private static func suffix(forRate rate: Int) -> String {
        rate == ConversionService.defaultSampleRate ? "" : "-\(rate / 1000)"
    }

    /// Where this track's converted file belongs, given the rate it'll be
    /// encoded at.
    func url(forSource source: URL, rate: Int) -> URL {
        switch self {
        case .besideMusic:
            let dir = source.deletingLastPathComponent()
                .appendingPathComponent(".mypod", isDirectory: true)
            let base = source.deletingPathExtension().lastPathComponent
            return dir.appendingPathComponent("\(base)\(Self.suffix(forRate: rate)).m4a")

        case .applicationSupport:
            let digest = SHA256.hash(data: Data(source.path.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            // Two-character fan-out so no single directory holds tens of
            // thousands of entries.
            return Self.versionedRoot(rate: rate)
                .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
                .appendingPathComponent("\(hex).m4a")
        }
    }

    /// The version marker for a converted file, or nil when the version is
    /// already encoded in the path and no marker is needed.
    ///
    /// The rate is in the marker's *name* so a `.mypod` folder holding both
    /// 44.1 and 48 kHz output doesn't have the two rates overwriting each
    /// other's version stamp.
    func versionMarker(forTarget target: URL, rate: Int) -> URL? {
        switch self {
        case .besideMusic:
            target.deletingLastPathComponent()
                .appendingPathComponent(".version\(Self.suffix(forRate: rate))")
        case .applicationSupport:
            nil
        }
    }

    /// Create the directory a converted file goes in.
    ///
    /// The Application Support tree is marked excluded from backup on the way —
    /// it's derived data, and Time Machine copying an entire re-encodable music
    /// library is pure waste. `.mypod` folders sit inside the user's own library
    /// and are left alone; excluding them would quietly change what a backup of
    /// *their* folder contains.
    func createDirectory(for target: URL) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard case .applicationSupport = self else { return }
        var root = Self.appSupportRoot
        guard (try? root.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true
        else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }
}

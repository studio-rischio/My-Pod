import Foundation

/// Measures and clears the converted-audio caches.
///
/// Both locations are always reported, not just the active one. Switching
/// location doesn't move anything, so whatever was written to the other place
/// is still on disk taking up room — and if it weren't shown, the only way to
/// find it would be to know it existed.
nonisolated enum CacheInventory: Sendable {
    struct Report: Sendable, Equatable {
        var appSupportBytes: UInt64 = 0
        var appSupportFiles: Int = 0
        var besideMusicBytes: UInt64 = 0
        var besideMusicFiles: Int = 0
        var besideMusicFolders: Int = 0
        /// Bytes held per quality setting, across both locations. A ceiling with
        /// no entry here has nothing cached.
        var byCeiling: [ConversionCeiling: UInt64] = [:]

        func bytes(for location: CacheLocation) -> UInt64 {
            switch location {
            case .applicationSupport: appSupportBytes
            case .besideMusic: besideMusicBytes
            }
        }

        /// What deleting the caches no iPod is set to would free.
        func unusedBytes(inUse: Set<ConversionCeiling>) -> UInt64 {
            byCeiling.reduce(0) { $0 &+ (inUse.contains($1.key) ? 0 : $1.value) }
        }
    }

    /// Walk both caches. I/O-bound over potentially thousands of files, so it's
    /// async and callers show a placeholder until it lands.
    static func scan(libraryRoot: URL?) async -> Report {
        await Task.detached(priority: .utility) {
            var report = Report()
            let (bytes, files) = directorySize(CacheLocation.appSupportRoot)
            report.appSupportBytes = bytes
            report.appSupportFiles = files

            // Enumerated once and reused. `mypodFolders` walks the whole music
            // library, so calling it per ceiling would walk it five times.
            let mypod = libraryRoot.map { mypodFolders(under: $0) } ?? []
            for folder in mypod {
                let (b, f) = directorySize(folder)
                report.besideMusicBytes &+= b
                report.besideMusicFiles += f
                report.besideMusicFolders += 1
            }

            // Per-ceiling totals, summed across both locations — the user cares
            // how much a quality setting costs them, not which tree it sits in.
            for ceiling in ConversionCeiling.allCases {
                var total = directorySize(CacheLocation.appSupportRoot(for: ceiling)).bytes
                for folder in mypod {
                    total &+= directorySize(
                        folder.appendingPathComponent(ceiling.rawValue, isDirectory: true)
                    ).bytes
                }
                if total > 0 { report.byCeiling[ceiling] = total }
            }
            return report
        }.value
    }

    // MARK: - Collecting

    /// Delete cached output for quality settings no iPod profile asks for.
    ///
    /// This is what keeps a per-ceiling cache bounded. Without it, trying all
    /// four settings would leave four encodings of the library on disk with
    /// nothing to say which are live — exactly the failure the 1.6 single-format
    /// cache existed to avoid.
    ///
    /// Runs at launch and after any profile change, so switching a device from
    /// one setting to another and back re-encodes rather than finding the old
    /// files still there. That's the deliberate trade: predictable disk use over
    /// a free undo.
    @discardableResult
    static func collectUnused(inUse: Set<ConversionCeiling>, libraryRoot: URL?) -> UInt64 {
        let fm = FileManager.default
        var freed: UInt64 = 0
        let mypod = libraryRoot.map { mypodFolders(under: $0) } ?? []
        // Every directory that holds per-ceiling subfolders. Both locations are
        // swept, not just the active one: a user who has switched cache location
        // has files in the other tree too, and they're just as unreferenced.
        let parents = [CacheLocation.versionedCacheRoot] + mypod

        for ceiling in ConversionCeiling.allCases where !inUse.contains(ceiling) {
            for dir in parents.map({ $0.appendingPathComponent(ceiling.rawValue, isDirectory: true) })
            where fm.fileExists(atPath: dir.path) {
                let (bytes, _) = directorySize(dir)
                do {
                    try fm.removeItem(at: dir)
                    freed &+= bytes
                } catch {
                    Log.convert.error("couldn't remove \(dir.path): \(error.localizedDescription)")
                }
            }
        }

        // A `.mypod` folder left holding nothing is litter in the user's music
        // library. Take it with us.
        for folder in mypod where (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }

        if freed > 0 {
            Log.convert.info("collected \(byteString(freed)) of converted files no iPod is set to")
        }
        return freed
    }

    private static func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }

    @discardableResult
    static func clearAppSupport() -> Bool {
        let root = CacheLocation.appSupportRoot
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        do {
            try FileManager.default.removeItem(at: root)
            Log.convert.info("cleared converted files in Application Support")
            return true
        } catch {
            Log.convert.error("couldn't clear Application Support cache: \(error.localizedDescription)")
            return false
        }
    }

    /// Remove every `.mypod` folder under the library root.
    @discardableResult
    static func clearBesideMusic(libraryRoot: URL?) -> Int {
        guard let root = libraryRoot else { return 0 }
        var removed = 0
        for folder in mypodFolders(under: root) {
            do {
                try FileManager.default.removeItem(at: folder)
                removed += 1
            } catch {
                Log.convert.error("couldn't remove \(folder.path): \(error.localizedDescription)")
            }
        }
        Log.convert.info("removed \(removed) .mypod folders from the music library")
        return removed
    }

    // MARK: - Walking

    /// `.mypod` is a dotfile, so the enumerator has to be told not to skip
    /// hidden entries — the default would find nothing at all.
    private static func mypodFolders(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in walker {
            guard url.lastPathComponent == ".mypod",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            found.append(url)
            // Nothing nested inside a cache folder is of further interest.
            walker.skipDescendants()
        }
        return found
    }

    private static func directorySize(_ dir: URL) -> (bytes: UInt64, files: Int) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return (0, 0) }

        var bytes: UInt64 = 0
        var files = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            bytes &+= UInt64(size)
            // Only the audio counts toward what the user thinks of as "cached
            // files" — version markers and part-files are noise.
            if url.pathExtension.lowercased() == "m4a" { files += 1 }
        }
        return (bytes, files)
    }
}

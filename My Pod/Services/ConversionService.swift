import Foundation

enum ConversionError: LocalizedError {
    case unsupported(URL)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let url): "Format not supported: \(url.lastPathComponent)"
        case .exportFailed(let m): "Export failed: \(m)"
        }
    }
}

/// Transcodes non-iPod-playable formats (FLAC, OGG, etc.) into AAC at
/// ~256 kbps inside an `.m4a` container by shelling out to macOS's bundled
/// `/usr/bin/afconvert`. Output goes wherever `CacheLocation` says — by default
/// `~/Library/Application Support/My Pod/Converted`, or a hidden `.mypod/`
/// folder inside the source album directory.
///
/// We previously tried AVAssetReader → AVAssetWriter for this so we could
/// embed metadata + artwork into the m4a directly. The result wouldn't play
/// on iPod Photo no matter how we patched the atom layout (esds, ftyp, hdlr).
/// afconvert produces iTunes-shaped files that play universally; iPod-side
/// metadata + artwork are set via libgpod (`itdb_track_set_thumbnails`,
/// `track->title`/`artist`/`album` etc.), so the m4a itself doesn't need any
/// embedded metadata for iPod use. Cost: previewing one of these files in
/// QuickLook or playing it in Music.app shows no tags.
// `nonisolated` — this is a stateless value type used from background tasks
// (sync engine + library store pre-convert). Overrides the project-wide
// MainActor default so we don't need `await` on every access to its statics.
nonisolated struct ConversionService: Sendable {
    /// Bump this whenever the conversion output format changes meaningfully —
    /// existing cached files will be regenerated on next sync/pre-convert.
    /// v8: switched audio engine from AVAssetWriter back to afconvert; iPod
    ///     Photo wouldn't play AVAssetWriter's m4a containers despite multiple
    ///     atom-shape patches.
    /// v9: `-s 3` (true VBR) → `-s 2` (constrained VBR — what iTunes uses).
    ///     `-b` is silently ignored under `-s 3` per Apple TN2271, and true VBR
    ///     produces files iPod firmware can't index for seeking. Also force
    ///     44.1 kHz output (`aac@44100`) — hi-res FLAC sources passing through
    ///     at 48/96 kHz were skipping on the iPod Photo.
    static let cacheVersion = "9"

    /// AAC encoder bit rate in bits/second.
    static let aacBitRate = 256_000

    /// How much bigger the encoder's real output runs than duration × bit rate.
    /// Constrained VBR (`-s 2`) overshoots the nominal rate on dense material,
    /// and the m4a container adds its own atoms on top. Measured over 18 FLAC
    /// tracks: 1.043 aggregate, 0.97–1.10 per track. Rounded up to 1.08 so a
    /// space budget errs toward leaving headroom rather than overfilling.
    static let vbrOverheadFactor = 1.08

    let maxConcurrent: Int

    /// Defaults to 2 — afconvert spawns one CoreAudio decode/encode pipeline
    /// per process and that pipeline doesn't tolerate >~4 concurrent instances
    /// in some configurations. AAC encoding is fast (~30× realtime per stream).
    init(maxConcurrent: Int = 2, cacheLocation: CacheLocation = .current) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.cacheLocation = cacheLocation
    }

    /// Where the user has chosen to keep converted files. Captured at init so
    /// a single sync run can't straddle a location change mid-flight.
    let cacheLocation: CacheLocation

    nonisolated func iPodPlayableURL(for track: LibraryTrack) -> URL {
        guard track.needsConversion else { return track.url }
        return cacheLocation.url(forSource: track.url)
    }

    /// Bytes this track will actually occupy on the iPod.
    ///
    /// Native files copy verbatim, so their source size is exact. Convertible
    /// ones land as AAC 256k m4a, which for FLAC is roughly a third of the
    /// source — budgeting against `sizeBytes` would badly under-fill the
    /// device. Three tiers, most accurate first:
    ///   1. already converted → measure the cached file
    ///   2. known duration (FLAC, via STREAMINFO) → duration × bitrate
    ///   3. neither → scale the source size by a per-format ratio
    nonisolated func estimatedIPodBytes(for track: LibraryTrack) -> UInt64 {
        guard track.needsConversion else { return track.sizeBytes }

        if isCached(track),
           let size = try? iPodPlayableURL(for: track)
               .resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 0 {
            return UInt64(size)
        }

        if track.durationMS > 0 {
            let bytesPerMS = Double(Self.aacBitRate) / 8.0 / 1000.0
            return UInt64(Double(track.durationMS) * bytesPerMS * Self.vbrOverheadFactor)
        }

        return UInt64(Double(track.sizeBytes) * Self.sizeRatio(track.fileExtension))
    }

    /// Fallback multipliers: (typical AAC 256k size) ÷ (typical source size),
    /// used only when we couldn't read a duration. Lossless sources shrink;
    /// the lossy ones we transcode from are usually encoded below 256k, so
    /// they grow.
    nonisolated private static func sizeRatio(_ ext: String) -> Double {
        switch ext.lowercased() {
        case "flac", "ape", "alac": 0.30   // ~850 kbps lossless → 256 kbps
        case "ogg", "wma":          1.30   // ~192 kbps → 256 kbps
        case "opus":                2.00   // ~128 kbps → 256 kbps
        default:                    1.00
        }
    }

    nonisolated func pending(_ tracks: [LibraryTrack]) -> [LibraryTrack] {
        tracks.filter { $0.needsConversion && !isCached($0) }
    }

    nonisolated func isCached(_ track: LibraryTrack) -> Bool {
        guard track.needsConversion else { return true }
        let target = iPodPlayableURL(for: track)
        guard cacheVersionMatches(target: target) else { return false }
        return isUpToDate(source: track.url, target: target)
    }

    nonisolated private func cacheVersionMatches(target: URL) -> Bool {
        // No marker means the version is already part of the path, so simply
        // finding a file there proves it was written by this version.
        guard let marker = cacheLocation.versionMarker(forTarget: target) else { return true }
        guard let data = try? Data(contentsOf: marker),
              let s = String(data: data, encoding: .utf8) else {
            return false
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) == Self.cacheVersion
    }

    nonisolated func convert(_ track: LibraryTrack, force: Bool = false) async throws -> URL {
        let target = iPodPlayableURL(for: track)
        guard track.needsConversion else { return track.url }
        if !force,
           cacheVersionMatches(target: target),
           isUpToDate(source: track.url, target: target) {
            Log.convert.debug("cache hit: \(track.title)")
            return target
        }

        try cacheLocation.createDirectory(for: target)
        let started = Date()
        Log.convert.debug("convert started\(force ? " (forced)" : ""): \(track.url.lastPathComponent)")
        do {
            try await export(source: track.url, to: target)
        } catch {
            Log.convert.error("convert failed: \(track.url.lastPathComponent) — \(error.localizedDescription)")
            throw error
        }
        if let marker = cacheLocation.versionMarker(forTarget: target) {
            try? Self.cacheVersion.data(using: .utf8)?.write(to: marker, options: [.atomic])
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.convert.info("convert ok: \(track.url.lastPathComponent) (\(ms) ms)")
        return target
    }

    nonisolated func ensure(
        tracks: [LibraryTrack],
        force: Bool = false,
        progress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> [URL: Result<URL, Error>] {
        let total = tracks.count
        var results: [URL: Result<URL, Error>] = [:]
        guard total > 0 else { return results }
        var completed = 0

        await withTaskGroup(of: (URL, Result<URL, Error>).self) { group in
            var iterator = tracks.makeIterator()
            for _ in 0..<min(maxConcurrent, total) {
                guard let t = iterator.next() else { break }
                group.addTask { await self.runOne(track: t, force: force) }
            }
            while let outcome = await group.next() {
                results[outcome.0] = outcome.1
                completed += 1
                progress(completed, total)
                // Stop scheduling once the calling task is cancelled. In-flight
                // afconvert subprocesses keep running to completion — the user
                // explicitly asked for "wait until the current job is finished
                // and then cancel" semantics.
                if Task.isCancelled { continue }
                if let next = iterator.next() {
                    group.addTask { await self.runOne(track: next, force: force) }
                }
            }
        }
        return results
    }

    // MARK: - Internals

    nonisolated private func runOne(track: LibraryTrack, force: Bool = false) async -> (URL, Result<URL, Error>) {
        do {
            let url = try await convert(track, force: force)
            return (track.url, .success(url))
        } catch {
            return (track.url, .failure(error))
        }
    }

    nonisolated private func isUpToDate(source: URL, target: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return false }
        let sourceMtime = (try? fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date) ?? .distantPast
        let targetMtime = (try? fm.attributesOfItem(atPath: target.path)[.modificationDate] as? Date) ?? .distantPast
        return targetMtime >= sourceMtime
    }

    nonisolated private func export(source: URL, to target: URL) async throws {
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).part")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.removeItem(at: target)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "m4af",                      // m4a file format
            "-d", "aac@44100",                 // AAC-LC, force 44.1 kHz (older iPods are flaky at 48k+)
            "-b", String(Self.aacBitRate),     // bitrate (only honored under -s 2 / -s 0, not -s 3)
            "-q", "127",                       // highest quality
            "-s", "2",                         // constrained VBR — same mode iTunes uses; -s 3 (true VBR) breaks iPod seeking
            source.path,
            tmp.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: tmp)
            throw ConversionError.exportFailed(msg.isEmpty ? "afconvert exit \(process.terminationStatus)" : msg)
        }

        try FileManager.default.moveItem(at: tmp, to: target)
    }
}

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

/// Transcodes non-iPod-playable formats (FLAC, OGG, etc.) into an `.m4a` the
/// device can play, by shelling out to macOS's bundled `/usr/bin/afconvert`.
/// The codec is AAC ~256 kbps by default; a lossless `ConversionCeiling` sends
/// lossless *sources* to ALAC instead, while lossy ones stay AAC whatever the
/// setting. Output goes wherever `CacheLocation` says — by default
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
    ///     The 44.1 kHz forcing and the AAC codec are now a default rather than
    ///     absolute — see `ConversionCeiling`. That isn't a version bump: output
    ///     at the default ceiling is byte-identical, and each ceiling's output
    ///     lives at its own path, so no two settings can be confused for each
    ///     other.
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

    /// `maxConcurrent` scales with the machine: half the logical cores, capped
    /// at 8, floored at 2.
    ///
    /// It used to be a flat 2, justified by a claim that afconvert "doesn't
    /// tolerate >~4 concurrent instances" because of a CoreAudio pipeline limit.
    /// That was wrong on both counts. The exclusivity it describes is an iOS
    /// hardware-codec concept — macOS AAC encoding is the *software* codec, so
    /// there's no scarce resource to contend over — and measurement found **zero
    /// failures at 32 concurrent instances**, eight times the asserted ceiling.
    ///
    /// The numbers behind the shape (M3 Ultra, 24 performance cores): scaling is
    /// near-linear to 8 — 7.06× on both the AAC and ALAC pipelines, 88% parallel
    /// efficiency — then rolls off to 12.5× at 16 and ~18× at 32, where the last
    /// step buys only 6–8%. So the cap is **politeness, not safety**: a sync
    /// shouldn't take the whole machine to save three minutes. Halving rather
    /// than using a constant keeps a 4-core Mac from being oversubscribed.
    ///
    /// Full method and results in `agent_space/bench-conversion.md`; re-run with
    /// `agent_space/bench-conversion.sh`.
    ///
    /// `ceiling` has **no default on purpose.** It is per-iPod now, so a default
    /// argument here would compile, run, and quietly encode for the wrong
    /// device — and under-reporting a lossless device's sizes by ~3× is exactly
    /// what makes a sync fill the iPod partway through the add phase, after
    /// removals have already run.
    init(
        maxConcurrent: Int = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2)),
        cacheLocation: CacheLocation = .current,
        ceiling: ConversionCeiling
    ) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.cacheLocation = cacheLocation
        self.ceiling = ceiling
    }

    /// Where the user has chosen to keep converted files. Captured at init so
    /// a single sync run can't straddle a location change mid-flight.
    let cacheLocation: CacheLocation

    /// The quality ceiling to encode against. Captured at init for the same
    /// reason as `cacheLocation` — a run that changed ceiling partway through
    /// would write half its output in one format and half in another, to paths
    /// that don't distinguish them.
    let ceiling: ConversionCeiling

    /// Whether this track is out of spec for the iPod this service is encoding
    /// for. The single place the rest of the app should ask.
    nonisolated func needsConversion(_ track: LibraryTrack) -> Bool {
        track.needsConversion(under: ceiling)
    }

    /// The sample rate this track's conversion targets.
    nonisolated func encodeRate(for track: LibraryTrack) -> Int {
        ceiling.encodeRate(sourceRate: track.format.sampleRate)
    }

    /// The codec this track's conversion produces. Lossy sources are always
    /// AAC, whatever the ceiling — see `ConversionCeiling.targetCodec`.
    nonisolated func targetCodec(for track: LibraryTrack) -> ConversionCeiling.Codec {
        ceiling.targetCodec(sourceIsLossless: track.format.isLossless)
    }

    /// How this track will be stored on the iPod, in the user's terms.
    nonisolated func targetFormatDescription(for track: LibraryTrack) -> String {
        guard needsConversion(track) else { return "Copied unchanged" }
        return switch targetCodec(for: track) {
        case .aac: "AAC \(Self.aacBitRate / 1000) kbps · \(rateLabel(for: track))"
        case .alac: "Apple Lossless 16-bit · \(rateLabel(for: track))"
        }
    }

    nonisolated private func rateLabel(for track: LibraryTrack) -> String {
        let khz = Double(encodeRate(for: track)) / 1000
        return khz == khz.rounded()
            ? String(format: "%.0f kHz", khz)
            : String(format: "%.1f kHz", khz)
    }

    nonisolated func iPodPlayableURL(for track: LibraryTrack) -> URL {
        guard needsConversion(track) else { return track.url }
        return cacheLocation.url(forSource: track.url, ceiling: ceiling)
    }

    /// Compressed size of ALAC as a fraction of the raw PCM it encodes.
    ///
    /// Real music lands between about 0.50 and 0.70 depending on density; a
    /// sparse recording compresses far better than a loud one. Rounded to the
    /// pessimistic end on purpose, for the same reason as `vbrOverheadFactor`:
    /// a space budget should err toward leaving headroom rather than
    /// overfilling a device that gives no warning when it runs out. Tier 1
    /// supersedes this the moment anything is actually converted.
    static let alacPCMRatio = 0.65

    /// Bytes this track will actually occupy on the iPod.
    ///
    /// Native files copy verbatim, so their source size is exact. Converted
    /// ones depend on the codec they land in, which is why this consults
    /// `targetCodec` rather than assuming AAC: the two differ by roughly 3×, and
    /// under-reporting is what silently defeats `SyncPlan.fits` and lets a sync
    /// fill the device partway through the add phase — after removals have
    /// already run.
    ///
    /// Three tiers, most accurate first:
    ///   1. already converted → measure the cached file
    ///   2. known duration → derive it from the target format
    ///   3. neither → scale the source size
    nonisolated func estimatedIPodBytes(for track: LibraryTrack) -> UInt64 {
        guard needsConversion(track) else { return track.sizeBytes }

        if isCached(track),
           let size = try? iPodPlayableURL(for: track)
               .resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 0 {
            return UInt64(size)
        }

        switch targetCodec(for: track) {
        case .aac:
            if track.format.durationMS > 0 {
                let bytesPerMS = Double(Self.aacBitRate) / 8.0 / 1000.0
                return UInt64(Double(track.format.durationMS) * bytesPerMS * Self.vbrOverheadFactor)
            }
            return UInt64(Double(track.sizeBytes) * Self.aacSizeRatio(track.fileExtension))

        case .alac:
            // Lossless output has no bitrate to multiply by — its size follows
            // the PCM it encodes, so derive that from the rate and depth the
            // encoder will actually write. Channel count isn't tracked; stereo
            // covers effectively all music, and a mono file simply comes in
            // under budget.
            if track.format.durationMS > 0 {
                let rate = Double(encodeRate(for: track))
                let bytesPerSample = 2.0            // always encoded at 16-bit
                let channels = 2.0
                let pcm = Double(track.format.durationMS) / 1000.0 * rate * bytesPerSample * channels
                return UInt64(pcm * Self.alacPCMRatio)
            }
            // No duration: scale the source instead. Both sides are lossless, so
            // FLAC → ALAC at matched rate and depth is near 1:1 (measured 1.015),
            // and anything the encoder downsamples or truncates shrinks in
            // proportion.
            return UInt64(Double(track.sizeBytes) * Self.losslessScale(for: track, targetRate: encodeRate(for: track)))
        }
    }

    /// Fallback multipliers for AAC output: (typical AAC 256k size) ÷ (typical
    /// source size), used only when we couldn't read a duration. Lossless
    /// sources shrink; the lossy ones we transcode from are usually encoded
    /// below 256k, so they grow.
    nonisolated private static func aacSizeRatio(_ ext: String) -> Double {
        switch ext.lowercased() {
        case "flac", "ape", "alac": 0.30   // ~850 kbps lossless → 256 kbps
        case "ogg", "wma":          1.30   // ~192 kbps → 256 kbps
        case "opus":                2.00   // ~128 kbps → 256 kbps
        default:                    1.00
        }
    }

    /// How much of a lossless source survives into 16-bit ALAC at `targetRate`.
    /// Capped at 1.05 — ALAC compresses slightly worse than FLAC, but a
    /// conversion never *grows* by more than that, and an unknown source format
    /// shouldn't be allowed to produce a wild over-estimate.
    nonisolated private static func losslessScale(for track: LibraryTrack, targetRate: Int) -> Double {
        var scale = 1.05
        if track.format.sampleRate > 0, targetRate < track.format.sampleRate {
            scale *= Double(targetRate) / Double(track.format.sampleRate)
        }
        if track.format.bitDepth > 16 {
            scale *= 16.0 / Double(track.format.bitDepth)
        }
        return min(scale, 1.05)
    }

    nonisolated func pending(_ tracks: [LibraryTrack]) -> [LibraryTrack] {
        tracks.filter { needsConversion($0) && !isCached($0) }
    }

    nonisolated func isCached(_ track: LibraryTrack) -> Bool {
        guard needsConversion(track) else { return true }
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
        guard needsConversion(track) else { return track.url }
        let rate = encodeRate(for: track)
        let codec = targetCodec(for: track)
        if !force,
           cacheVersionMatches(target: target),
           isUpToDate(source: track.url, target: target) {
            Log.convert.debug("cache hit: \(track.title)")
            return target
        }

        try cacheLocation.createDirectory(for: target)
        let started = Date()
        Log.convert.debug("convert started\(force ? " (forced)" : ""): \(track.url.lastPathComponent) → \(codec.rawValue) @ \(rate) Hz")
        do {
            try await export(source: track.url, to: target, rate: rate, codec: codec)
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

    nonisolated private func export(
        source: URL,
        to target: URL,
        rate: Int,
        codec: ConversionCeiling.Codec
    ) async throws {
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).part")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.removeItem(at: target)

        switch codec {
        case .aac:
            try await run([
                "-f", "m4af",                      // m4a file format
                "-d", "aac@\(rate)",               // AAC-LC at the ceiling's rate — 44.1 kHz unless the user opted up (older iPods are flaky at 48k+)
                "-b", String(Self.aacBitRate),     // bitrate (only honored under -s 2 / -s 0, not -s 3)
                "-q", "127",                       // highest quality
                "-s", "2",                         // constrained VBR — same mode iTunes uses; -s 3 (true VBR) breaks iPod seeking
                source.path,
                tmp.path,
            ], cleaningUp: [tmp])

        case .alac:
            // Two passes, and not by choice. afconvert exposes no bit-depth flag
            // for ALAC and defaults to 32-bit source data, so a direct
            // `-d alac@44100` yields a 32-bit file — larger than the 24-bit
            // original, and out of spec by this app's own rules, which re-encode
            // lossless above 16 bits. Even a 16-bit FLAC comes back 32-bit.
            // Going through explicit 16-bit PCM is the only way to pin the depth.
            // Verified against the bench set: a 24-bit/96 kHz source lands at
            // exactly the byte count of the known-good 16-bit/44.1 kHz file.
            let pcm = target.deletingLastPathComponent()
                .appendingPathComponent(".\(target.lastPathComponent).pcm.caf")
            try? FileManager.default.removeItem(at: pcm)
            defer { try? FileManager.default.removeItem(at: pcm) }

            try await run([
                "-f", "caff",
                "-d", "LEI16@\(rate)",             // 16-bit little-endian PCM at the target rate
                source.path,
                pcm.path,
            ], cleaningUp: [pcm, tmp])

            try await run([
                "-f", "m4af",
                "-d", "alac",                      // depth and rate both come from the PCM above
                pcm.path,
                tmp.path,
            ], cleaningUp: [pcm, tmp])
        }

        try FileManager.default.moveItem(at: tmp, to: target)
    }

    /// One afconvert invocation. `cleaningUp` is removed if it fails, so a
    /// half-written intermediate never survives to be mistaken for output.
    nonisolated private func run(_ arguments: [String], cleaningUp: [URL]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = arguments
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
            for url in cleaningUp { try? FileManager.default.removeItem(at: url) }
            throw ConversionError.exportFailed(msg.isEmpty ? "afconvert exit \(process.terminationStatus)" : msg)
        }
    }
}

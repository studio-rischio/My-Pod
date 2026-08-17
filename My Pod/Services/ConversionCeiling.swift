import Foundation

/// The highest audio quality My Pod will put on the iPod, and the format it
/// converts into.
///
/// A **ceiling**, not a target. Material above it is brought down to it;
/// material below it is left exactly as it is. A 128 kbps MP3 stays a 128 kbps
/// MP3 under every setting here — re-encoding it would cost quality to gain
/// nothing, and the iPod plays it fine.
///
/// "Above the ceiling" means out of spec — sample rate, bit depth, or a codec
/// profile the hardware mishandles. It deliberately does *not* mean bitrate: a
/// 320 kbps MP3 is not re-encoded under the AAC 256 setting, because
/// transcoding lossy to lossy compounds artefacts to save a little space.
///
/// The default is the lowest rung, and stays there. The failure modes are
/// asymmetric: an unnecessary re-encode costs a little quality on a device
/// whose output stage is 16-bit anyway, while a file that turns out to be
/// unplayable costs a silent skip on hardware with no error reporting. The
/// higher rungs are for someone who knows their own iPod — see the bench
/// results in `agent_space/ipod-test-files/results.txt`.
///
/// `nonisolated` because the scanner and conversion service both read this from
/// detached tasks — overrides the project-wide MainActor default.
nonisolated enum ConversionCeiling: String, CaseIterable, Sendable, Identifiable {
    /// AAC 256 kbps, 44.1 kHz. Every click-wheel iPod handles this.
    case aac44
    /// AAC 256 kbps, 48 kHz. Bench test F.
    case aac48
    /// Apple Lossless, 16-bit / 44.1 kHz. Bench test A.
    case alac44
    /// Apple Lossless, 24-bit / 48 kHz. Bench test B.
    case alac48

    var id: String { rawValue }

    nonisolated enum Codec: String, Sendable {
        case aac, alac
    }

    // MARK: - What the ceiling means

    var codec: Codec {
        switch self {
        case .aac44, .aac48: .aac
        case .alac44, .alac48: .alac
        }
    }

    /// Highest sample rate allowed through untouched, and the ceiling the
    /// encoder targets when it does convert.
    var maxSampleRate: Int {
        switch self {
        case .aac44, .alac44: AudioFormat.baseSampleRate
        case .aac48, .alac48: 48_000
        }
    }

    /// Deepest lossless material allowed through untouched.
    ///
    /// Only ever a passthrough rule. Anything this app *encodes* is written at
    /// 16-bit regardless, because the iPod's output stage is 16-bit and a
    /// 24-bit re-encode would be 50% larger for no audible difference. The
    /// 24-bit rung exists to stop Apple Music Lossless files being re-encoded
    /// at all, not to produce 24-bit output.
    var maxBitDepth: Int {
        switch self {
        case .aac44, .aac48, .alac44: 16
        case .alac48: 24
        }
    }

    /// Sample rate to hand the encoder for a source at `sourceRate`.
    ///
    /// Never resamples upward, and prefers halving to landing on the ceiling so
    /// a conversion stays inside its own rate family: 96 → 48 and 88.2 → 44.1
    /// are exact 2:1 decimations where 88.2 → 48 would be an arbitrary ratio.
    /// That isn't only tidiness — `agent_space/crackle-test` measured
    /// intersample overshoot nearly tripling through a rate conversion, and
    /// clean ratios are the cheapest way not to add to it.
    ///
    /// An unknown rate (0) falls back to 44.1 kHz rather than guessing upward.
    func encodeRate(sourceRate: Int) -> Int {
        let base = AudioFormat.baseSampleRate
        guard sourceRate > 0 else { return base }
        guard sourceRate > maxSampleRate else { return sourceRate }

        var rate = sourceRate
        while rate > maxSampleRate {
            let halved = rate / 2
            // Below 44.1 kHz we'd be discarding audible bandwidth to preserve a
            // ratio — take the ceiling instead.
            guard halved >= base else { break }
            rate = halved
        }
        return min(rate, maxSampleRate)
    }

    /// Which codec this track is actually encoded into.
    ///
    /// Lossless sources follow the ceiling. **Lossy sources always become AAC**,
    /// even under a lossless ceiling: a 128 kbps OGG re-encoded as ALAC would be
    /// roughly six times larger and recover nothing, because the detail was
    /// discarded at the original encode. The ceiling raises a limit; it can't
    /// put back what was never there.
    func targetCodec(sourceIsLossless: Bool) -> Codec {
        sourceIsLossless ? codec : .aac
    }

    // MARK: - Preference

    private static let key = "MyPod.conversionCeiling"

    /// 1.5's key. Read once at migration time, then removed — see `migrate()`.
    private static let legacyKey = "MyPod.conversionProfile"

    /// Posted when the ceiling changes. Everything derived from it is stale:
    /// which tracks need converting is decided at *scan* time and baked into
    /// `LibraryTrack`, so observers rescan rather than merely refreshing.
    static let didChange = Notification.Name("MyPod.conversionCeilingChanged")

    static var current: ConversionCeiling {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = ConversionCeiling(rawValue: raw)
        else { return .aac44 }
        return value
    }

    /// Record a new ceiling. Callers are responsible for clearing the converted
    /// -file cache first — see `SettingsView`, which confirms with the user
    /// before doing either. Cached output is *not* keyed by the ceiling, so a
    /// change that didn't clear would keep serving files in the old format
    /// forever, silently.
    static func setCurrent(_ ceiling: ConversionCeiling) {
        guard ceiling != current else { return }
        UserDefaults.standard.set(ceiling.rawValue, forKey: key)
        Log.convert.info("conversion ceiling: \(ceiling.rawValue)")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// One-time upgrade from 1.5's `ConversionProfile`.
    ///
    /// 1.5 kept output from different sample rates side by side, suffixing the
    /// cache path (`v9-48/`, `Track-48.m4a`). This model clears on change
    /// instead, so those suffixes are gone — which means a 1.5 user who had
    /// selected 48 kHz would now resolve to the *unsuffixed* path and be served
    /// the 44.1 kHz file sitting there. Only they need clearing; anyone who
    /// stayed on the default has a cache that is still exactly correct, and
    /// re-encoding their library for nothing would be its own bug.
    ///
    /// Returns true if it cleared anything, so the caller can log it.
    @discardableResult
    static func migrate(libraryRoot: URL?) -> Bool {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: legacyKey) else { return false }
        defaults.removeObject(forKey: legacyKey)

        // maximumCompatibility was 1.5's default and produced identical output
        // to this model's default, at the same path.
        guard legacy != "maximumCompatibility" else { return false }

        defaults.set(ConversionCeiling.aac48.rawValue, forKey: key)
        CacheInventory.clearAppSupport()
        CacheInventory.clearBesideMusic(libraryRoot: libraryRoot)
        Log.convert.info("migrated 1.5 conversion profile '\(legacy)' — cleared the rate-keyed cache")
        return true
    }

    // MARK: - Display

    var title: String {
        switch self {
        case .aac44: "AAC 256 kbps · 44.1 kHz"
        case .aac48: "AAC 256 kbps · 48 kHz"
        case .alac44: "Apple Lossless · 16-bit / 44.1 kHz"
        case .alac48: "Apple Lossless · 24-bit / 48 kHz"
        }
    }

    var detail: String {
        switch self {
        case .aac44:
            "The safest option, and the one every click-wheel iPod is known to handle. Music above CD quality is re-encoded down to it."
        case .aac48:
            "48 kHz files play as they are instead of being re-encoded, and hi-res music converts to 48 kHz rather than 44.1. Verified on an iPod Photo; older models have been reported to skip at this rate."
        case .alac44:
            "FLAC and other lossless music is kept lossless instead of becoming AAC — roughly three times larger on the iPod. Lossy music (OGG, Opus, WMA) still becomes AAC, since converting it to lossless would only make it bigger."
        case .alac48:
            "As above, and 24-bit lossless up to 48 kHz passes through untouched, sparing Apple Music Lossless files a re-encode. Anything actually converted is still written at 16-bit, which is what the iPod's output stage is."
        }
    }

    /// Rough multiplier on library size, for the settings blurb. The iPod's
    /// output is 16-bit at every rung, so this is the only axis that differs in
    /// any way the user can act on.
    var sizeNote: String {
        switch codec {
        case .aac:
            "Smallest on the iPod, and easiest on its battery."
        case .alac:
            // Worth stating before someone files it as a regression. It isn't
            // decode cost so much as I/O: files roughly 3× larger empty the
            // playback buffer 3× as often, and spinning the drive back up is
            // what actually drains a click-wheel iPod.
            "About 3× the size of AAC for lossless music, and shorter battery life on the iPod — larger files mean its drive spins up more often."
        }
    }
}

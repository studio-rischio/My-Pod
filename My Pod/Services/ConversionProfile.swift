import Foundation

/// How aggressively music is re-encoded before it reaches the iPod.
///
/// The default re-encodes anything above 44.1 kHz or 16-bit, which is tighter
/// than the hardware is documented to accept and tighter than some hardware
/// demonstrably plays. That is deliberate — see the design principle in
/// CLAUDE.md. The failure modes are asymmetric: an unnecessary re-encode costs
/// a little quality on a device whose output stage is 16-bit anyway, while a
/// file passed through that turns out to be unplayable costs a silent skip on
/// hardware with no error reporting.
///
/// The looser levels exist because the tighter one is a floor, not a ceiling.
/// Bench testing on an iPod Photo (see `agent_space/ipod-test-files/results.txt`)
/// found 48 kHz AAC and 24-bit/48 kHz ALAC both playing cleanly, so a user who
/// knows their own hardware can spare those files a re-encode. What that test
/// cannot show is the *absence* of failure: the finding that pinned the default
/// to 44.1 kHz in the first place was intermittent skipping across a full album,
/// and a twenty-second clip playing correctly does not disprove it. Hence
/// opt-in, per user, with the safe behaviour left as the default.
///
/// 96 and 192 kHz stay converted at every level — those genuinely refused to
/// play, which is the one thing the bench test established outright.
///
/// `nonisolated` because the library scanner and conversion service both read
/// this from detached tasks — overrides the project-wide MainActor default.
nonisolated enum ConversionProfile: String, CaseIterable, Sendable, Identifiable {
    /// 44.1 kHz, 16-bit. Everything else re-encoded.
    case maximumCompatibility
    /// Adds 48 kHz. Bench test F.
    case allow48kHz
    /// Adds 24-bit lossless up to 48 kHz. Bench test B.
    case allow48kHzAnd24Bit

    var id: String { rawValue }

    // MARK: - Rules

    /// Highest sample rate allowed through without re-encoding, and the ceiling
    /// the encoder targets when it does re-encode.
    var maxSampleRate: Int {
        switch self {
        case .maximumCompatibility: AudioFormat.maxSampleRate
        case .allow48kHz, .allow48kHzAnd24Bit: 48_000
        }
    }

    /// Whether lossless material deeper than 16 bits passes through.
    ///
    /// Click-wheel output is a 16-bit pipeline either way, so this never gains
    /// audible resolution — it only skips a re-encode that would have been
    /// transparent. The reason it is separable from the sample rate at all is
    /// that the two were tested separately and failed separately.
    var allows24BitLossless: Bool { self == .allow48kHzAnd24Bit }

    /// Sample rate to hand the encoder for a source at `sourceRate`.
    ///
    /// Never resamples upward, and prefers halving to landing on the ceiling so
    /// a conversion stays inside its own rate family: 96 → 48 and 88.2 → 44.1
    /// are exact 2:1 decimations, where 88.2 → 48 would be an arbitrary ratio.
    /// That matters beyond tidiness — `agent_space/crackle-test` measured
    /// intersample overshoot nearly tripling through a sample-rate conversion
    /// (+1.02 dB from a 96 kHz source against +0.40 dB at 44.1), and clean
    /// ratios are the cheapest way to not add to it.
    ///
    /// An unknown rate (0) falls back to 44.1 kHz rather than guessing upward.
    func encodeRate(sourceRate: Int) -> Int {
        let ceiling = maxSampleRate
        guard sourceRate > 0 else { return AudioFormat.maxSampleRate }
        guard sourceRate > ceiling else { return sourceRate }

        var rate = sourceRate
        while rate > ceiling {
            let halved = rate / 2
            // Below 44.1 kHz we would be throwing away audible bandwidth to
            // preserve a ratio — take the ceiling instead.
            guard halved >= AudioFormat.maxSampleRate else { break }
            rate = halved
        }
        return min(rate, ceiling)
    }

    // MARK: - Preference

    private static let key = "MyPod.conversionProfile"

    /// Posted when the profile changes. Everything derived from it is stale at
    /// that point — which tracks need converting is decided at *scan* time and
    /// baked into `LibraryTrack`, so observers have to rescan, not just refresh.
    static let didChange = Notification.Name("MyPod.conversionProfileChanged")

    static var current: ConversionProfile {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = ConversionProfile(rawValue: raw)
        else { return .maximumCompatibility }
        return value
    }

    static func setCurrent(_ profile: ConversionProfile) {
        guard profile != current else { return }
        UserDefaults.standard.set(profile.rawValue, forKey: key)
        Log.convert.info("conversion profile: \(profile.rawValue)")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: - Display

    var title: String {
        switch self {
        case .maximumCompatibility: "Maximum compatibility"
        case .allow48kHz: "Allow 48 kHz"
        case .allow48kHzAnd24Bit: "Allow 48 kHz and 24-bit"
        }
    }

    var summary: String {
        switch self {
        case .maximumCompatibility: "44.1 kHz, 16-bit"
        case .allow48kHz: "48 kHz, 16-bit"
        case .allow48kHzAnd24Bit: "48 kHz, 24-bit"
        }
    }

    var detail: String {
        switch self {
        case .maximumCompatibility:
            "Everything above CD quality is re-encoded to AAC at 44.1 kHz. The safest option, and the one every click-wheel iPod is known to handle."
        case .allow48kHz:
            "48 kHz files play as they are instead of being re-encoded, and hi-res music converts to 48 kHz rather than 44.1. Verified on an iPod Photo; older models have been reported to skip at this rate."
        case .allow48kHzAnd24Bit:
            "Also passes 24-bit lossless through untouched, sparing Apple Music Lossless files a re-encode. The iPod's output is 16-bit regardless, so this saves conversion time rather than adding detail."
        }
    }
}

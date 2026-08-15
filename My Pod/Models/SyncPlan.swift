import Foundation

/// One track to be present on the iPod after sync.
struct PlannedTrack: Sendable, Equatable, Hashable {
    let library: LibraryTrack
    /// File to copy onto the iPod (native source URL or converted .m4a in `.mypod/`).
    let sourceURL: URL
    /// True if this track requires (or required) a FLAC/etc → AAC pre-pass.
    let needsConversion: Bool
}

/// What a sync will do to one playlist, worked out by diffing the M3U store
/// against the playlists currently on the iPod.
///
/// The sync itself always wipes and rewrites every user playlist, so this is
/// purely descriptive — it exists so the sheet can say "these three playlists
/// change" instead of silently rewriting all of them.
struct PlaylistChange: Sendable, Equatable, Identifiable {
    /// Declared in the order the sheet lists them.
    enum Kind: String, Sendable, CaseIterable { case added, removed, modified, unchanged }

    var name: String
    var kind: Kind
    /// Entries the iPod copy will gain.
    var entriesAdded: Int
    /// Entries the iPod copy will lose — either dropped from the .m3u, or their
    /// track is leaving the device.
    var entriesRemoved: Int
    /// Entry count the playlist will have on the iPod once the sync is done.
    var finalCount: Int
    /// Entries in the .m3u that resolve to no track on the post-sync iPod
    /// (unchecked in the library, or missing from disk). They're silently
    /// dropped from the iPod copy, so surface them rather than let the numbers
    /// look wrong.
    var unresolvedCount: Int

    var id: String { name }
}

/// Result of computing what the next sync would do.
struct SyncPlan: Sendable, Equatable {
    /// Tracks that aren't on the iPod yet.
    var toAdd: [PlannedTrack]
    /// iPod tracks that aren't in the desired set anymore.
    var toRemove: [TrackInfo]
    /// Tracks already on the iPod that match the plan.
    var unchangedCount: Int
    /// Tracks needing conversion that aren't yet cached.
    var pendingConversion: [LibraryTrack]
    /// Estimated bytes the additions will occupy *on the iPod*, so transcoded
    /// tracks are counted at their delivered size rather than their source size.
    var addedBytes: UInt64
    var removedBytes: UInt64

    /// Free space on the mounted volume when the plan was made. Zero when the
    /// caller didn't supply it, which disables the capacity check rather than
    /// failing every sync.
    var freeBytesBefore: UInt64 = 0

    /// Bytes this sync needs beyond what the device can give it, or zero if it
    /// fits. Removals run before additions, so the space they free counts.
    var shortfallBytes: UInt64 {
        guard freeBytesBefore > 0 || removedBytes > 0 else { return 0 }
        let available = freeBytesBefore &+ removedBytes
        return addedBytes > available ? addedBytes &- available : 0
    }

    var fits: Bool { shortfallBytes == 0 }
    var playlistCount: Int
    /// Per-playlist diff against what's on the iPod now, sorted added →
    /// removed → modified → unchanged.
    var playlistChanges: [PlaylistChange] = []

    var toAddCount: Int { toAdd.count }
    var toRemoveCount: Int { toRemove.count }

    func playlists(_ kind: PlaylistChange.Kind) -> [PlaylistChange] {
        playlistChanges.filter { $0.kind == kind }
    }

    var changedPlaylists: [PlaylistChange] {
        playlistChanges.filter { $0.kind != .unchanged }
    }

    var hasWork: Bool {
        !toAdd.isEmpty || !toRemove.isEmpty || !pendingConversion.isEmpty
            || !changedPlaylists.isEmpty
    }
}

struct SyncProgress: Sendable, Equatable {
    /// Declared in execution order — `SyncPhaseWeights` walks the cases in
    /// order to work out how much of the run is already behind us.
    enum Phase: String, Sendable, CaseIterable { case converting, removing, adding, playlists, saving }
    var phase: Phase
    var completed: Int
    var total: Int
    /// Free-form detail line — typically "Artist — Title" of the track being processed.
    var detail: String?
    /// Wall-clock start of the current phase. The view uses it together with
    /// `completed`/`total` to compute ETA via a `TimelineView` ticker. Nil
    /// for short phases (saving) where ETA isn't meaningful.
    var phaseStartedAt: Date?
}

/// Collapses the five sync phases into a single 0–1 fraction for the Dock bar.
///
/// A per-phase bar would rewind to zero five times over one sync, which reads
/// as broken at dock-icon size. Phases are weighted by how long they actually
/// take: transcoding a track dwarfs copying one, which dwarfs writing a
/// playlist entry. Weights scale with each phase's item count and are
/// normalized over the run, so a sync with nothing to convert doesn't stall at
/// the start waiting for a phase that has no work.
struct SyncPhaseWeights: Sendable, Equatable {
    /// Relative cost of one item in each phase. Ratios are rough — they only
    /// need to keep the bar moving at a roughly even rate, not predict time.
    private static let perItem: [SyncProgress.Phase: Double] = [
        .converting: 6.0,    // afconvert run — the dominant cost
        .removing:   0.2,    // database edit, no file copy
        .adding:     1.0,    // copy one file to the iPod
        .playlists:  0.5,    // per playlist, not per entry
        // `saving` is deliberately absent — it's flat, see `savingCost`.
    ]

    /// `saving` has one "item" however big the sync was, but writing the
    /// iTunesDB and rendering thumbnails is far from instant — give it a flat
    /// share so the bar doesn't sit pinned at 100% through the slowest part.
    private static let savingCost = 10.0

    private let weights: [SyncProgress.Phase: Double]

    init(plan: SyncPlan) {
        let counts: [SyncProgress.Phase: Double] = [
            .converting: Double(plan.pendingConversion.count),
            .removing:   Double(plan.toRemoveCount),
            .adding:     Double(plan.toAddCount),
            .playlists:  Double(plan.playlistCount),
        ]
        var w = counts.reduce(into: [SyncProgress.Phase: Double]()) { acc, entry in
            acc[entry.key] = entry.value * (Self.perItem[entry.key] ?? 0)
        }
        w[.saving] = Self.savingCost
        weights = w
    }

    /// Total across every phase. Floored at 1 so an empty plan can't divide by
    /// zero — `saving` alone already guarantees a positive total in practice.
    private var total: Double { max(weights.values.reduce(0, +), 1) }

    func fraction(at progress: SyncProgress) -> Double {
        var done = 0.0
        for phase in SyncProgress.Phase.allCases {
            let weight = weights[phase] ?? 0
            guard phase != progress.phase else {
                let within = progress.total > 0
                    ? Double(progress.completed) / Double(progress.total)
                    : 0
                done += weight * min(max(within, 0), 1)
                break
            }
            done += weight
        }
        return min(max(done / total, 0), 1)
    }
}

struct SyncOutcome: Sendable, Equatable {
    var added: Int
    var removed: Int
    var skipped: Int
    var failed: Int
    var convertedFailures: Int
    var totalOnDevice: Int
    var cancelled: Bool
    /// Playlists written to the iPod that weren't there before.
    var playlistsAdded: Int = 0
    /// Playlists that were on the iPod and are gone now.
    var playlistsRemoved: Int = 0
    /// Playlists that survived but whose contents changed.
    var playlistsUpdated: Int = 0
}

enum SyncState: Equatable, Sendable {
    case idle
    case planning
    case planned(SyncPlan)
    case running(SyncProgress)
    case finished(SyncOutcome)
    case failed(String)
}

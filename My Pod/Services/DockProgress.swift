// DockProgress.swift
//
// Paints a Finder-download-style progress strip across the bottom of the app's
// Dock icon while a sync (or a standalone pre-conversion) is running. macOS
// shows the same tile in the Command-Tab switcher, so the bar is visible from
// both.
//
// **Always-installed contentView** — the obvious design swaps
// `dockTile.contentView` between a custom NSView (active) and `nil` (idle),
// but `contentView = nil` is unreliable: the tile often keeps the last-drawn
// view until some unrelated refresh happens, leaving a stuck bar after the
// sync finished. Instead the view is installed once and an `isActive` flag
// flips what it draws. Idle renders the app icon alone, which is visually
// identical to the default tile.
//
// **Observation** — driven by a `withObservationTracking` loop rather than a
// SwiftUI `.onChange`. The dock has to follow `SyncEngine.state` and
// `MusicLibraryStore.conversionState`, and ContentView's body doesn't read
// either of them (the sync sheet does). A view-body observer would therefore
// miss most transitions — including the one back to idle, which is exactly
// the one that leaves a stuck bar.

import AppKit
import Foundation
import Observation

/// What the dock tile should show. Equatable so the bridge can skip redraws
/// when an observation fires without changing anything dock-relevant.
enum DockSnapshot: Equatable, Sendable {
    case idle
    /// `fraction` is in [0, 1]. `indeterminate` covers phases with no
    /// meaningful count yet (planning), where the bar renders a small constant
    /// sliver rather than claiming a percentage.
    case active(fraction: Double, indeterminate: Bool)
}

@MainActor
final class DockProgressBridge {
    static let shared = DockProgressBridge()

    private let dockTile = NSApplication.shared.dockTile
    private let contentView = DockTileContentView()
    private var installed = false
    private var lastSnapshot: DockSnapshot?

    func update(snapshot: DockSnapshot) {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        installIfNeeded()
        switch snapshot {
        case .idle:
            // Reset the numbers too, so re-entering active doesn't flash a
            // stale fraction for one frame.
            contentView.isActive = false
            contentView.fraction = 0
            contentView.indeterminate = false
            Log.ui.debug("dock: idle")
        case let .active(fraction, indeterminate):
            contentView.isActive = true
            contentView.fraction = fraction
            contentView.indeterminate = indeterminate
            Log.ui.debug("dock: \(Int(fraction * 100))%\(indeterminate ? " (indeterminate)" : "")")
        }
        contentView.needsDisplay = true
        dockTile.display()
    }

    /// Installed lazily rather than in `init` — the dock tile isn't reliably
    /// wired up at launch on every macOS version, and installing too early can
    /// produce a one-frame blank tile.
    private func installIfNeeded() {
        guard !installed else { return }
        dockTile.contentView = contentView
        installed = true
    }
}

/// Watches the sync engine and library store, pushing a snapshot to the bridge
/// whenever either changes.
@MainActor
final class DockProgressTracker {
    static let shared = DockProgressTracker()

    private weak var engine: SyncEngine?
    private weak var store: MusicLibraryStore?
    private var started = false

    /// Idempotent — safe to call from a `.task` that re-runs.
    func start(engine: SyncEngine, store: MusicLibraryStore) {
        guard !started else { return }
        started = true
        self.engine = engine
        self.store = store
        observe()
    }

    /// `withObservationTracking` is a one-shot subscription, so we re-register
    /// from `onChange` to keep following changes for the life of the app.
    private func observe() {
        withObservationTracking {
            DockProgressBridge.shared.update(snapshot: currentSnapshot())
        } onChange: {
            // onChange fires from `willSet`, before the new value is stored.
            // Hop to the next main-actor tick so we read the settled state.
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
    }

    private func currentSnapshot() -> DockSnapshot {
        // A full sync outranks a standalone pre-conversion: the sync runs its
        // own conversion phase, so both can be live at once.
        if let engine {
            switch engine.state {
            case .planning:
                return .active(fraction: 0, indeterminate: true)
            case .running:
                guard let fraction = engine.overallFraction else {
                    return .active(fraction: 0, indeterminate: true)
                }
                return .active(fraction: fraction, indeterminate: false)
            case .idle, .planned, .finished, .failed:
                break
            }
        }
        if let store, case let .running(completed, total, _) = store.conversionState {
            let fraction = total > 0 ? Double(completed) / Double(total) : 0
            return .active(fraction: fraction, indeterminate: false)
        }
        return .idle
    }
}

/// The dock tile's `contentView`: the app icon, plus a rounded progress strip
/// across the bottom when `isActive`. Drawn at 128×128; macOS scales the
/// result to whatever dock icon size the user has set.
private final class DockTileContentView: NSView {
    var fraction: Double = 0
    var indeterminate: Bool = false
    /// Master switch. False means "draw only the icon" — the tile then looks
    /// exactly like the system default, without relying on
    /// `dockTile.contentView = nil`.
    var isActive: Bool = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Clear the backing store first. The icon draws with .sourceOver, so
        // its transparent edge pixels composite *over* whatever was there
        // rather than replacing it — without this, going active → idle leaves
        // the old bar showing through the icon's transparent lower edge.
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.clear(bounds)
        }

        NSApplication.shared.applicationIconImage?.draw(in: bounds)
        guard isActive else { return }

        // Lower 14% of the tile, inset 8% each side — clear of the badge slot
        // macOS reserves at bottom-right.
        let inset = bounds.width * 0.08
        let barHeight = bounds.height * 0.14
        let bottomGap = bounds.height * 0.10
        let track = NSRect(
            x: bounds.minX + inset,
            y: bounds.minY + bottomGap,
            width: bounds.width - 2 * inset,
            height: barHeight
        )
        let radius = barHeight / 2

        // Dark backdrop + hairline, so the bar reads against any icon artwork
        // and any dock background.
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        let border = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()

        // Indeterminate draws a constant sliver: visible, without implying a
        // completion percentage we don't know.
        let shown = indeterminate ? 0.18 : min(max(fraction, 0), 1)
        guard shown > 0 else { return }
        let fill = NSRect(
            x: track.minX,
            y: track.minY,
            // Never narrower than the pill's own cap, or it renders as a wedge.
            width: max(track.width * CGFloat(shown), radius * 2),
            height: track.height
        )
        (NSColor(named: "AccentColor") ?? .controlAccentColor).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

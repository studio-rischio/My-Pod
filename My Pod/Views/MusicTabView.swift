import SwiftUI
import UniformTypeIdentifiers

struct MusicTabView: View {
    @Bindable var store: MusicLibraryStore

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                pickRoot()
            } label: {
                Label(store.libraryRoot == nil ? "Choose Library Folder…" : "Change Library Folder…", systemImage: "folder")
            }

            if let root = store.libraryRoot {
                Text(root.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(root.path)
            }

            Spacer()

            if store.newTrackCount > 0 {
                Label("\(store.newTrackCount) new", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .imageScale(.small)
                    .monospacedDigit()
                    .help("Tracks in your library that aren't on the iPod yet")
            }

            switch store.scanState {
            case .scanning:
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            case .ready(let date):
                Text("Scanned \(date.formatted(.relative(presentation: .numeric)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    store.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
            case .empty:
                Text("No tracks found").font(.caption).foregroundStyle(.secondary)
                Button("Rescan") { store.rescan() }
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if store.libraryRoot == nil {
            chooseRootEmptyState
        } else {
            HSplitView {
                LibraryTreeView(store: store)
                    .frame(minWidth: 360)
                detailPanel
                    .frame(minWidth: 240)
            }
        }
    }

    private var chooseRootEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No music library selected")
                .font(.title3)
            Text("Pick a Plex-structured folder: Library/Artist/Album/Track")
                .foregroundStyle(.secondary)
            Button("Choose Library Folder…") { pickRoot() }
                .controlSize(.large)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Selection")
                .font(.headline)

            HStack {
                Text("Tracks:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.selectionTrackCount) of \(store.library.totalTracks)")
                    .monospacedDigit()
            }
            HStack {
                Text("Size:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(byteCount(store.selectionSize))
                    .monospacedDigit()
            }

            HStack {
                Button("Select All") { store.selectAll() }
                    .disabled(store.library.totalTracks == 0)
                Button("Clear") { store.clearSelection() }
                    .disabled(store.selectedTrackPaths.isEmpty)
            }

            Divider()

            newMusicSection

            Divider()

            conversionSection

            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var newMusicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Music")
                .font(.headline)

            Toggle("Select new music automatically", isOn: $store.autoSelectNewMusic)
                .help("Check new albums as they appear — newest first, for as long as the iPod has room.")

            if store.deviceSnapshot == nil {
                Text("Connect your iPod to see what's new.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.newTrackCount == 0 {
                Text("Everything in your library is on the iPod.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Not on iPod:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.newTrackCount) tracks in \(store.newAlbumIDs.count) albums")
                        .monospacedDigit()
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private var conversionSection: some View {
        let pendingCount = store.pendingConversion.count
        let nonNativeCount = store.selectedNeedingConversion.count

        VStack(alignment: .leading, spacing: 8) {
            Text("Conversion")
                .font(.headline)

            if nonNativeCount == 0 {
                Text("All selected tracks are iPod-native.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Need conversion:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(nonNativeCount - pendingCount) cached, \(pendingCount) pending")
                        .monospacedDigit()
                        .font(.callout)
                }

                switch store.conversionState {
                case .idle, .finished:
                    HStack(spacing: 8) {
                        Button {
                            store.runConversion()
                        } label: {
                            Label("Pre-convert \(pendingCount)", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(pendingCount == 0)
                        Button {
                            store.runConversion(force: true)
                        } label: {
                            Label("Re-convert all", systemImage: "arrow.clockwise")
                        }
                        .help("Re-encode every selected non-native track, ignoring the cache.")
                        .disabled(nonNativeCount == 0)
                    }
                    if case let .finished(ok, failed, cancelled) = store.conversionState {
                        Text(cancelled
                             ? "Cancelled — \(ok) ok, \(failed) failed before stopping"
                             : "Last run: \(ok) ok, \(failed) failed")
                            .font(.caption)
                            .foregroundStyle(failed > 0 || cancelled ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    }
                case let .running(completed, total, startedAt):
                    runningView(completed: completed, total: total, startedAt: startedAt)
                }
            }
        }
    }

    /// The progress UI ticks once per second via `TimelineView` so the ETA
    /// label refreshes without the store needing its own timer.
    private func runningView(completed: Int, total: Int, startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(completed), total: Double(total))
            HStack {
                Text("Converting \(completed) of \(total)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(etaLabel(now: ctx.date, completed: completed, total: total, startedAt: startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Cancel") {
                    store.cancelConversion()
                }
                .controlSize(.small)
            }
        }
    }

    /// Format an ETA from elapsed time + completed count. We need at least one
    /// completed track to extrapolate; before that, just say "estimating…".
    private func etaLabel(now: Date, completed: Int, total: Int, startedAt: Date) -> String {
        guard completed > 0, total > completed else { return "" }
        let elapsed = now.timeIntervalSince(startedAt)
        let perTrack = elapsed / Double(completed)
        let remaining = max(0, perTrack * Double(total - completed))
        return "~\(formatDuration(remaining)) remaining"
    }

    private func pickRoot() {
        Log.ui.info("user opened library folder picker")
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick your Plex-structured music library root."
        if panel.runModal() == .OK, let url = panel.url {
            store.chooseRoot(url)
        } else {
            Log.ui.info("library folder picker cancelled")
        }
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    let m = s / 60
    let sec = s % 60
    if m < 60 { return "\(m)m \(sec)s" }
    let h = m / 60
    let min = m % 60
    return "\(h)h \(min)m"
}

private func byteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
}

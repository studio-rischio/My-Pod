import SwiftUI

struct SyncSheetView: View {
    @Bindable var engine: SyncEngine
    let onCommit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(minWidth: 480, minHeight: 280)
            Divider()
            footer
        }
        .frame(width: 540)
    }

    private var header: some View {
        HStack {
            Text("Sync")
                .font(.headline)
            Spacer()
            stateBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch engine.state {
        case .idle: EmptyView()
        case .planning:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Planning…").foregroundStyle(.secondary) }
        case .planned:
            Text("Ready").foregroundStyle(.secondary)
        case .running(let p):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(engine.isCancelling ? "Cancelling…" : phaseLabel(p.phase))
                    .foregroundStyle(.secondary)
            }
        case .finished(let outcome):
            if outcome.cancelled {
                Label("Cancelled", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
            } else {
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch engine.state {
        case .idle, .planning:
            ProgressView("Computing what needs to change…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .planned(let plan):
            planView(plan)
        case .running(let progress):
            runningView(progress)
        case .finished(let outcome):
            finishedView(outcome)
        case .failed(let msg):
            failedView(msg)
        }
    }

    private func planView(_ plan: SyncPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !plan.hasWork {
                    Label("iPod is already in sync.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                }

                summaryRow("Add", count: plan.toAddCount, bytes: plan.addedBytes, color: .accentColor)
                summaryRow("Remove", count: plan.toRemoveCount, bytes: plan.removedBytes, color: .red)
                summaryRow("Unchanged", count: plan.unchangedCount, color: .secondary)
                summaryRow("Convert (→AAC)", count: plan.pendingConversion.count, color: .orange)

                playlistSection(plan)

                if !plan.toRemove.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("To remove (\(plan.toRemoveCount)):")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(plan.toRemove.prefix(20), id: \.id) { t in
                            Text("• \(t.artist) — \(t.album) — \(t.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if plan.toRemoveCount > 20 {
                            Text("…and \(plan.toRemoveCount - 20) more.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    /// Playlists are wiped and rewritten on every sync, so the counts alone
    /// would say nothing. List the ones whose contents actually differ from
    /// what's on the iPod now; collapse the rest into a one-line footnote.
    @ViewBuilder
    private func playlistSection(_ plan: SyncPlan) -> some View {
        let changed = plan.changedPlaylists
        let unchanged = plan.playlists(.unchanged).count

        if !changed.isEmpty || plan.playlistCount > 0 {
            Divider().padding(.vertical, 4)
            HStack(spacing: 6) {
                Text("Playlists")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if !changed.isEmpty {
                    playlistCountBadge(count: plan.playlists(.added).count, kind: .added)
                    playlistCountBadge(count: plan.playlists(.modified).count, kind: .modified)
                    playlistCountBadge(count: plan.playlists(.removed).count, kind: .removed)
                }
            }

            if changed.isEmpty {
                Text("No playlist changes (\(plan.playlistCount) in sync).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(changed.prefix(20)) { change in
                        playlistChangeRow(change)
                    }
                    if changed.count > 20 {
                        Text("…and \(changed.count - 20) more.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if unchanged > 0 {
                        Text("\(unchanged) other playlist\(unchanged == 1 ? "" : "s") unchanged.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    // Entries pointing at tracks that won't be on the iPod are
                    // dropped silently during the write phase — say so, or the
                    // per-playlist track counts look wrong.
                    let unresolved = plan.playlistChanges.reduce(0) { $0 + $1.unresolvedCount }
                    if unresolved > 0 {
                        Text("\(unresolved) playlist entr\(unresolved == 1 ? "y" : "ies") skipped — not selected for sync.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func playlistCountBadge(count: Int, kind: PlaylistChange.Kind) -> some View {
        if count > 0 {
            Label("\(count)", systemImage: playlistSymbol(kind))
                .font(.caption)
                .foregroundStyle(playlistColor(kind))
                .labelStyle(.titleAndIcon)
        }
    }

    private func playlistChangeRow(_ change: PlaylistChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: playlistSymbol(change.kind))
                .foregroundStyle(playlistColor(change.kind))
                .font(.caption)
            Text(change.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(playlistDetail(change))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func playlistSymbol(_ kind: PlaylistChange.Kind) -> String {
        switch kind {
        case .added: "plus.circle.fill"
        case .removed: "minus.circle.fill"
        case .modified: "arrow.triangle.2.circlepath"
        case .unchanged: "equal.circle"
        }
    }

    private func playlistColor(_ kind: PlaylistChange.Kind) -> Color {
        switch kind {
        case .added: .accentColor
        case .removed: .red
        case .modified: .orange
        case .unchanged: .secondary
        }
    }

    /// Right-hand column: what the playlist ends up as, and how it got there.
    private func playlistDetail(_ change: PlaylistChange) -> String {
        switch change.kind {
        case .added:
            return "new · \(change.finalCount) tracks"
        case .removed:
            return "removed · was \(change.entriesRemoved) tracks"
        case .modified:
            var parts: [String] = []
            if change.entriesAdded > 0 { parts.append("+\(change.entriesAdded)") }
            if change.entriesRemoved > 0 { parts.append("−\(change.entriesRemoved)") }
            return "\(parts.joined(separator: " ")) · \(change.finalCount) tracks"
        case .unchanged:
            return "\(change.finalCount) tracks"
        }
    }

    private func runningView(_ progress: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(phaseLabel(progress.phase))
                .font(.title3)

            let showsBar = progress.total > 0
                && (progress.phase == .converting
                    || progress.phase == .removing
                    || progress.phase == .adding
                    || progress.phase == .playlists)

            if showsBar {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                HStack {
                    Text("\(progress.completed) of \(progress.total)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    // ETA ticks once a second from a TimelineView so the
                    // estimate refreshes between completed-track updates.
                    if let started = progress.phaseStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(etaLabel(now: ctx.date,
                                          completed: progress.completed,
                                          total: progress.total,
                                          startedAt: started))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            } else {
                ProgressView()
            }

            if let detail = progress.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if progress.phase == .saving {
                Text("Writing iTunesDB and rendering artwork thumbnails…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if engine.isCancelling {
                Text("Stopping after the current track. Partial progress will be saved.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Linear ETA: elapsed / completed gives seconds-per-track, multiply by
    /// remaining. Empty string when we don't have enough data yet.
    private func etaLabel(now: Date, completed: Int, total: Int, startedAt: Date) -> String {
        guard completed > 0, total > completed else { return "" }
        let elapsed = now.timeIntervalSince(startedAt)
        let perItem = elapsed / Double(completed)
        let remaining = max(0, perItem * Double(total - completed))
        return "~\(formatDuration(remaining)) remaining"
    }

    private func finishedView(_ outcome: SyncOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if outcome.cancelled {
                Label("Sync cancelled", systemImage: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            } else {
                Label("Sync complete", systemImage: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
            summaryRow("Added", count: outcome.added, color: .accentColor)
            summaryRow("Removed", count: outcome.removed, color: .red)
            summaryRow("Skipped (unchanged)", count: outcome.skipped, color: .secondary)
            if outcome.failed > 0 {
                summaryRow("Failed", count: outcome.failed, color: .orange)
            }
            if outcome.convertedFailures > 0 {
                summaryRow("Conversion failures", count: outcome.convertedFailures, color: .orange)
            }
            if outcome.playlistsAdded > 0 {
                summaryRow("Playlists added", count: outcome.playlistsAdded, color: .accentColor)
            }
            if outcome.playlistsUpdated > 0 {
                summaryRow("Playlists updated", count: outcome.playlistsUpdated, color: .orange)
            }
            if outcome.playlistsRemoved > 0 {
                summaryRow("Playlists removed", count: outcome.playlistsRemoved, color: .red)
            }
            Divider()
            Text("\(outcome.totalOnDevice) tracks now on the iPod.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failedView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            Text(msg)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryRow(_ label: String, count: Int, bytes: UInt64? = nil, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).frame(width: 200, alignment: .leading)
            Text("\(count)").monospacedDigit().fontWeight(.medium)
            Spacer()
            if let bytes, bytes > 0 {
                Text(byteCount(bytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .font(.callout)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch engine.state {
            case .idle, .planning:
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
            case .planned(let plan):
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.hasWork ? "Sync" : "Sync Anyway") { onCommit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .running:
                Button(engine.isCancelling ? "Cancelling…" : "Cancel") {
                    engine.cancel()
                }
                .disabled(engine.isCancelling)
                .keyboardShortcut(.cancelAction)
            case .finished, .failed:
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func close() {
        engine.reset()
        dismiss()
    }

    private func phaseLabel(_ phase: SyncProgress.Phase) -> String {
        switch phase {
        case .converting: "Converting tracks…"
        case .removing: "Removing tracks…"
        case .adding: "Copying tracks to iPod…"
        case .playlists: "Writing playlists…"
        case .saving: "Saving database…"
        }
    }
}

private func byteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
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

import SwiftUI

/// Conversion status and the pre-convert controls.
///
/// Lives on the General tab's Library section, but every number it shows is
/// derived from the Music tab's *selection* — the cache is only ever primed for
/// tracks that are actually going to sync. Away from the checkboxes that drive
/// it, that relationship isn't self-evident, so the labels say "selected"
/// explicitly rather than leaving a bare count to be misread as library-wide.
struct ConversionSectionView: View {
    let store: MusicLibraryStore

    var body: some View {
        let pendingCount = store.pendingConversion.count
        let nonNativeCount = store.selectedNeedingConversion.count

        VStack(alignment: .leading, spacing: 8) {
            if store.libraryRoot == nil {
                Text("Choose a music library to see what needs converting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if nonNativeCount == 0 {
                Text("Every selected track is iPod-native — nothing to convert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Selected tracks needing conversion:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(nonNativeCount - pendingCount) cached, \(pendingCount) pending")
                        .monospacedDigit()
                        .font(.callout)
                }
                .help("FLAC, OGG, Opus, WMA and APE files, plus any AAC or ALAC whose contents are above the quality ceiling set in Settings. Cached conversions are reused; pending ones are encoded during the next sync unless you pre-convert them here.")

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
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// completed track to extrapolate; before that, just say nothing.
    private func etaLabel(now: Date, completed: Int, total: Int, startedAt: Date) -> String {
        guard completed > 0, total > completed else { return "" }
        let elapsed = now.timeIntervalSince(startedAt)
        let perTrack = elapsed / Double(completed)
        let remaining = max(0, perTrack * Double(total - completed))
        return "~\(conversionDuration(remaining)) remaining"
    }
}

private func conversionDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    let m = s / 60
    let sec = s % 60
    if m < 60 { return "\(m)m \(sec)s" }
    let h = m / 60
    let min = m % 60
    return "\(h)h \(min)m"
}

import SwiftUI

/// The manual transfer's progress panel.
///
/// Deliberately the same shell as `SyncSheetView` — same width, same
/// header/content/footer split, same state badge, same button placement. What
/// changes between library mode and manual mode is the machinery underneath;
/// the experience of committing a change to the iPod should not.
///
/// The one honest difference is that there's no plan to review. A sync has to
/// tell you what it worked out; here the queue is already on screen and you
/// built it yourself, so the first pane confirms the cost rather than
/// enumerating the contents.
struct ManualSheetView: View {
    @Bindable var store: ManualTransferStore
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
            Text("Manual Changes")
                .font(.headline)
            Spacer()
            stateBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch store.state {
        case .idle, .loading:
            EmptyView()
        case .adding, .removing, .saving:
            ProgressView().controlSize(.small)
        case .finished(let outcome):
            Label(outcome.cancelled ? "Cancelled" : "Done",
                  systemImage: outcome.cancelled ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(outcome.cancelled ? .orange : .green)
                .font(.callout)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            queueView
        case .adding(let completed, let total, let detail):
            progressView("Adding music", completed: completed, total: total, detail: detail)
        case .removing(let completed, let total, let detail):
            progressView("Removing music", completed: completed, total: total, detail: detail)
        case .saving:
            progressView("Saving to iPod", completed: 0, total: 0, detail: "Writing the database and artwork")
        case .finished(let outcome):
            finishedView(outcome)
        case .failed(let message):
            failedView(message)
        }
    }

    // MARK: - Panes

    private var queueView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryRow("Add", count: newCount, bytes: store.pending.adding, color: .accentColor)
                summaryRow("Remove", count: store.markedForRemoval.count, bytes: store.pending.removing, color: .red)
                if alreadyThere > 0 {
                    summaryRow("Already on iPod", count: alreadyThere, color: .secondary)
                }
                if convertCount > 0 {
                    summaryRow("Convert", count: convertCount, color: .orange)
                }

                Label(
                    "Only the tracks you marked are removed. Everything else on this iPod is left exactly as it is.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if !store.queuedTracks.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Queued (\(store.queuedTracks.count)):")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.queuedTracks.prefix(20), id: \.id) { track in
                            Text("\(track.artist) — \(track.title)")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if store.queuedTracks.count > 20 {
                            Text("…and \(store.queuedTracks.count - 20) more")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func progressView(_ title: String, completed: Int, total: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3)
            if total > 0 {
                ProgressView(value: Double(completed), total: Double(total))
                Text("\(completed) of \(total)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func finishedView(_ outcome: ManualTransferOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(outcome.cancelled ? "Stopped after the current track" : "Finished")
                .font(.title3)
            summaryRow("Added", count: outcome.added, color: .accentColor)
            if outcome.removed > 0 { summaryRow("Removed", count: outcome.removed, color: .red) }
            if outcome.skipped > 0 { summaryRow("Already on iPod", count: outcome.skipped, color: .secondary) }
            if outcome.failed > 0 { summaryRow("Failed", count: outcome.failed, color: .orange) }
            if outcome.cancelled {
                Label(
                    "Everything transferred before you cancelled has been saved to the iPod.",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn't finish", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch store.state {
            case .idle, .loading:
                Button("Cancel") { dismiss() }
                Button("Apply") { onCommit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.hasPendingChanges)
            case .adding, .removing:
                Button("Cancel") { store.cancel() }
            case .saving:
                // Never offer a way out mid-save: the iTunesDB is being written.
                Button("Cancel") { }.disabled(true)
            case .finished, .failed:
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Arithmetic

    /// Queued tracks not already on the device — what will actually be added.
    private var newCount: Int {
        let onDevice = Set(store.deviceTracks.map { TrackKey(ipod: $0) })
        return store.queuedTracks.filter { !onDevice.contains(TrackKey(library: $0)) }.count
    }

    private var alreadyThere: Int { store.queuedTracks.count - newCount }

    private var convertCount: Int {
        let ceiling = DeviceProfileStore.shared.active.ceiling
        let onDevice = Set(store.deviceTracks.map { TrackKey(ipod: $0) })
        return store.queuedTracks.filter {
            !onDevice.contains(TrackKey(library: $0)) && $0.needsConversion(under: ceiling)
        }.count
    }

    private func summaryRow(_ label: String, count: Int, bytes: UInt64? = nil, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
            Spacer()
            if let bytes, bytes > 0 {
                Text(SyncEngine.byteString(bytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("\(count)")
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}

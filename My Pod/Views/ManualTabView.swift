import AppKit
import SwiftUI

struct ManualTabView: View {
    let controller: IPodController
    @Bindable var store: ManualTransferStore

    @State private var showAddConfirm = false
    @State private var showRemoveConfirm = false
    @State private var dropTargeted = false

    private var profileStore: DeviceProfileStore { .shared }

    var body: some View {
        Group {
            if controller.status == .ready, let device = controller.device {
                HStack(alignment: .top, spacing: 0) {
                    addPane(device: device)
                        .frame(
                            minWidth: 330,
                            idealWidth: 390,
                            maxWidth: 520,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )

                    Divider()

                    devicePane(device: device)
                        .frame(
                            minWidth: 450,
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
            } else {
                unavailableState
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .task(id: controller.snapshot) {
            await store.refresh(device: controller.device)
        }
    }

    private func addPane(device: IPodDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Music")
                .font(.headline)

            dropZone

            HStack {
                Button("Add Files…", action: chooseFiles)
                Button("Add Folder…", action: chooseFolder)
                Spacer()
                if !store.queuedTracks.isEmpty {
                    Button("Clear") { store.clearQueue() }
                        .disabled(store.isBusy)
                }
            }

            Divider()

            if store.queuedTracks.isEmpty {
                ContentUnavailableView(
                    "No Music Queued",
                    systemImage: "music.note",
                    description: Text("Drop files or a folder above. Adding music never removes tracks already on the iPod.")
                )
            } else {
                List(store.queuedTracks) { track in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .lineLimit(1)
                            Text("\(track.artist) — \(track.album)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(track.fileExtension.uppercased())
                            .font(.caption2)
                            .foregroundStyle(
                            track.needsConversion(under: profileStore.active.ceiling)
                                ? AnyShapeStyle(Color.orange)
                                : AnyShapeStyle(.secondary)
                        )
                        Button {
                            store.removeQueued(url: track.url)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isBusy)
                    }
                }
            }

            operationStatus

            HStack {
                if store.isBusy {
                    Button("Cancel") { store.cancel() }
                }
                Spacer()
                Button("Add \(store.queuedTracks.count) to iPod") {
                    showAddConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.queuedTracks.isEmpty || store.isBusy)
            }
        }
        .padding(16)
        .confirmationDialog(
            "Add \(store.queuedTracks.count) track\(store.queuedTracks.count == 1 ? "" : "s") to this iPod?",
            isPresented: $showAddConfirm,
            titleVisibility: .visible
        ) {
            Button("Add to iPod") {
                Task {
                    await store.addQueued(
                        to: device,
                        freeBytes: controller.storage.free
                    )
                    controller.refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing music is preserved. Tracks already on the iPod are skipped; nothing is removed.")
        }
    }

    private func devicePane(device: IPodDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Music on iPod")
                    .font(.headline)
                Spacer()
                Text("\(store.deviceTracks.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    Task { await store.refresh(device: device) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh tracks on iPod")
                .disabled(store.isBusy)
            }

            Table(store.filteredDeviceTracks, selection: $store.selectedDeviceTrackIDs) {
                TableColumn("Title") { track in
                    Text(track.title.isEmpty ? "Untitled" : track.title)
                }
                TableColumn("Artist") { track in
                    Text(track.artist)
                }
                TableColumn("Album") { track in
                    Text(track.album)
                }
            }
            .searchable(text: $store.searchText, prompt: "Search iPod")

            HStack {
                Text("\(store.selectedDeviceTrackIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Remove Selected…", role: .destructive) {
                    showRemoveConfirm = true
                }
                .disabled(store.selectedDeviceTrackIDs.isEmpty || store.isBusy)
            }
        }
        .padding(16)
        .confirmationDialog(
            "Remove \(store.selectedDeviceTrackIDs.count) selected track\(store.selectedDeviceTrackIDs.count == 1 ? "" : "s") from this iPod?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove from iPod", role: .destructive) {
                Task {
                    await store.removeSelected(from: device)
                    controller.refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the selected tracks are removed. All other music on the iPod is left untouched.")
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 32))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
            Text("Drop music files or folders here")
                .fontWeight(.medium)
            Text("Files are queued first; nothing is written until you confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.enqueue(urls: urls) }
            return !urls.isEmpty
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
    }

    @ViewBuilder
    private var operationStatus: some View {
        switch store.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Reading files…").font(.caption).foregroundStyle(.secondary)
            }
        case let .adding(completed, total, detail):
            progressRow(label: "Adding", completed: completed, total: total, detail: detail)
        case let .removing(completed, total, detail):
            progressRow(label: "Removing", completed: completed, total: total, detail: detail)
        case .saving:
            HStack {
                ProgressView().controlSize(.small)
                Text("Saving iPod database…").font(.caption).foregroundStyle(.secondary)
            }
        case let .finished(outcome):
            Text(summary(outcome))
                .font(.caption)
                .foregroundStyle(outcome.failed > 0 || outcome.cancelled ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func progressRow(label: String, completed: Int, total: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
            Text("\(label) \(completed) of \(total) — \(detail)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var unavailableState: some View {
        ContentUnavailableView(
            controller.status == .opening ? "Opening iPod…" : "No iPod Connected",
            systemImage: "ipod",
            description: Text(controller.status == .opening
                              ? "Manual management becomes available as soon as the iPod database is ready."
                              : "Connect an iPod in disk mode to add or remove individual songs.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Music to Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            Task { await store.enqueue(urls: panel.urls) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder of Music to Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            Task { await store.enqueue(urls: panel.urls) }
        }
    }

    private func summary(_ outcome: ManualTransferOutcome) -> String {
        let prefix = outcome.cancelled ? "Cancelled — " : "Last operation: "
        return "\(prefix)\(outcome.added) added, \(outcome.removed) removed, \(outcome.skipped) already present, \(outcome.failed) failed"
    }
}

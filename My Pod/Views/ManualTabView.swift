import AppKit
import SwiftUI

struct ManualTabView: View {
    let controller: IPodController
    @Bindable var store: ManualTransferStore

    @State private var dropTargeted = false

    private var profileStore: DeviceProfileStore { .shared }

    var body: some View {
        Group {
            if controller.status == .ready, let device = controller.device {
                // What's on the iPod leads, and the changes you're staging sit
                // beside it — you read the device first, then act on it.
                HStack(alignment: .top, spacing: 0) {
                    devicePane(device: device)
                        .frame(
                            minWidth: 450,
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )

                    Divider()

                    addPane()
                        .frame(
                            minWidth: 330,
                            idealWidth: 390,
                            maxWidth: 520,
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

    private func addPane() -> some View {
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
                // Spans the pane deliberately. `ContentUnavailableView` centres
                // its own contents, but only within whatever width it is given —
                // and the enclosing VStack is `.leading`, so at its intrinsic
                // width it sits left of centre. It only looked right at the
                // minimum window size, where the two happen to coincide.
                ContentUnavailableView(
                    "No Music Queued",
                    systemImage: "music.note",
                    description: Text("Drop files or a folder above. Adding music never removes tracks already on the iPod.")
                )
                .frame(maxWidth: .infinity)
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


            // No primary button here on purpose. Committing the queue is the
            // Sync button in the bottom bar — the same place, and the same
            // gesture, as every other "make the iPod match what I set up". A
            // second prominent button competing with it would be the surprise.
            if store.isBusy {
                HStack {
                    Button("Cancel") { store.cancel() }
                    Spacer()
                }
            }
        }
        .padding(16)
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

            // Marked rows are struck through and dimmed rather than removed
            // from the list: they're still on the iPod until Sync runs, and
            // hiding them would misrepresent what the device currently holds.
            Table(store.filteredDeviceTracks, selection: $store.selectedDeviceTrackIDs) {
                TableColumn("Title") { track in
                    Text(track.title.isEmpty ? "Untitled" : track.title)
                        .strikethrough(store.isMarkedForRemoval(track))
                        .foregroundStyle(store.isMarkedForRemoval(track) ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                }
                TableColumn("Artist") { track in
                    Text(track.artist)
                        .strikethrough(store.isMarkedForRemoval(track))
                        .foregroundStyle(store.isMarkedForRemoval(track) ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                }
                TableColumn("Album") { track in
                    Text(track.album)
                        .strikethrough(store.isMarkedForRemoval(track))
                        .foregroundStyle(store.isMarkedForRemoval(track) ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                }
            }
            .searchable(text: $store.searchText, prompt: "Search iPod")

            HStack {
                if store.markedForRemoval.isEmpty {
                    Text("\(store.selectedDeviceTrackIDs.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("\(store.markedForRemoval.count) marked for removal")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .monospacedDigit()
                    Button("Undo") { store.clearMarkedForRemoval() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(store.isBusy)
                }
                Spacer()
                // Marks rather than deletes: nothing reaches the iPod until Sync,
                // so a mis-click is undoable and the cost shows up in the storage
                // bar first — the same bargain library mode offers.
                Button("Remove Selected") { store.markSelectedForRemoval() }
                    .disabled(store.selectedDeviceTrackIDs.isEmpty || store.isBusy)
            }
        }
        .padding(16)
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

}

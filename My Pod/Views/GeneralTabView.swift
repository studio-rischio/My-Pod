import SwiftUI

struct GeneralTabView: View {
    @Bindable var controller: IPodController
    @Bindable var libraryStore: MusicLibraryStore
    @Bindable var playlistStore: PlaylistStore
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Device state first, then Library. Library is deliberately
                // outside the connected/disconnected branch: choosing folders
                // is the first thing a new user does, and requiring an iPod to
                // be plugged in before the app will let them do it is backwards.
                if let info = controller.deviceInfo {
                    deviceSection(info)
                } else {
                    noDeviceSection
                }

                librarySection

                if controller.deviceInfo != nil {
                    dangerZone
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func deviceSection(_ info: DeviceInfo) -> some View {
        GroupBox("Device") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("Name", info.displayName)
                infoRow("Model", info.modelName)
                if !info.generation.isEmpty {
                    infoRow("Generation", info.generation)
                }
                // Two different capacities, and they only agree on a stock
                // iPod: the volume is what's actually installed, `capacityGB`
                // is what libgpod's model table says this model shipped with.
                // Showing both would be noise on an unmodified device, so the
                // stock row appears only when the drive has been changed.
                infoRow("Capacity", byteCount(controller.effectiveCapacityBytes))
                    .help("Reported by the mounted volume — the drive actually installed.")
                if controller.hasNonStockDrive {
                    infoRow("Stock capacity", String(format: "%.0f GB", info.capacityGB))
                        .help("What this iPod model shipped with, per libgpod's model table. It differs from the installed capacity, so this drive has been replaced.")
                }
                infoRow("Tracks", "\(info.trackCount)")
                infoRow("Playlists", "\(info.playlistCount)")
                if let uuid = info.uuid {
                    infoRow("UUID", uuid)
                        .textSelection(.enabled)
                }
                infoRow("Mount", info.mountpoint.path)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        }

    }

    // MARK: - Library

    private var librarySection: some View {
        GroupBox("Library") {
            VStack(alignment: .leading, spacing: 12) {
                pathRow(
                    label: "Music",
                    path: libraryStore.libraryRoot?.path,
                    placeholder: "No folder chosen",
                    help: "A Plex-structured folder: Library/Artist/Album/Track."
                ) {
                    if let url = FolderPicker.chooseLibraryRoot() {
                        libraryStore.chooseRoot(url)
                    }
                }

                pathRow(
                    label: "Playlists",
                    path: playlistStore.directory.path,
                    placeholder: "",
                    help: "The folder My Pod reads .m3u playlists from."
                ) {
                    if let url = FolderPicker.choosePlaylistFolder() {
                        playlistStore.chooseDirectory(url)
                    }
                }

                Divider()

                Text("Conversion")
                    .font(.subheadline)
                    .fontWeight(.medium)
                ConversionSectionView(store: libraryStore)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One folder setting: label, current path, and the button that changes it.
    private func pathRow(
        label: String,
        path: String?,
        placeholder: String,
        help: String,
        change: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            if let path {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(path == nil ? "Choose…" : "Change…", action: change)
        }
        .help(help)
    }

    // MARK: - Danger zone

    private var dangerZone: some View {
        GroupBox("Danger Zone") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset iPod").fontWeight(.medium)
                    Text("Wipes all music files, artwork, and the database. The iPod ends up empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Reset…") {
                    Log.ui.info("user clicked Reset iPod")
                    showResetConfirm = true
                }
                    .tint(.red)
                    .disabled(controller.status != .ready)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Reset iPod entirely?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset iPod", role: .destructive) {
                Log.ui.info("user confirmed Reset iPod")
                controller.fullReset()
            }
            Button("Cancel", role: .cancel) {
                Log.ui.info("user cancelled Reset iPod")
            }
        } message: {
            Text("All music, artwork, and database files will be deleted. This cannot be undone.")
        }
    }

    /// Deliberately a compact box rather than the full-height empty state it
    /// used to be. Library settings sit directly below and have to stay on
    /// screen with nothing plugged in — a 320pt placeholder would push them
    /// under the fold on exactly the run where they matter most.
    private var noDeviceSection: some View {
        GroupBox("Device") {
            HStack(spacing: 14) {
                Image(systemName: "ipod")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No iPod connected")
                        .font(.headline)
                    Text("Plug an iPod in and put it in disk mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func byteCount(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

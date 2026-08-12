import SwiftUI

struct GeneralTabView: View {
    @Bindable var controller: IPodController
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let info = controller.deviceInfo {
                    deviceSection(info)
                } else {
                    placeholderSection
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

        GroupBox("Sync Options") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Library and conversion options will appear here.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

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

    private var placeholderSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "ipod")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No iPod connected")
                .font(.title3)
            Text("Plug an iPod into a USB port to get started.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
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

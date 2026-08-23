import SwiftUI

struct HeaderView: View {
    let info: DeviceInfo?
    let status: IPodController.Status
    /// Installed capacity in bytes, and whether it differs from what the model
    /// shipped with. Both come from `IPodController`, which is the only place
    /// that sees the model table and the mounted volume together.
    let capacityBytes: UInt64
    let hasNonStockDrive: Bool
    /// Whose settings and selection the tabs below are editing.
    let profile: DeviceProfile
    let onEject: () -> Void
    let onIdentify: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            summaryRow
            if info?.needsIdentification == true {
                identifyBanner
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "ipod")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryLine)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(secondaryLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            editingBadge
            if status == .ready {
                Button {
                    Log.ui.info("user clicked Eject")
                    onEject()
                } label: {
                    Label("Eject", systemImage: "eject.fill")
                }
                .help("Unmount and eject the iPod")
            }
            statusBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Shown when libgpod can't tell what iPod this is.
    ///
    /// Worth a banner rather than a line in the log because the consequence is
    /// invisible: the sync reports success, the covers are right there in the
    /// library, and none of them reach the device. Nothing else in the app
    /// would ever tell the user why.
    private var identifyBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This iPod isn't identified, so album art won't sync")
                    .fontWeight(.medium)
                Text("Restoring an iPod no longer writes the file that says which model it is. Tell My Pod which iPod this is and it will write it for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Identify iPod…", action: onIdentify)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var primaryLine: String {
        info?.displayName ?? "No iPod connected"
    }

    private var secondaryLine: String {
        guard let info else {
            switch status {
            case .opening: return "Opening…"
            case .error(let m): return m
            // The General tab used to carry this hint; it no longer has an
            // empty state to put it in, and it matters — a click-wheel iPod
            // that isn't in disk mode never mounts, so the app simply never
            // sees it and the user has no idea why.
            default: return "Connect an iPod via USB and put it in disk mode"
            }
        }
        // Lead with the installed capacity — on a re-drived iPod the model's
        // stock figure is the misleading one. It's appended in parentheses only
        // when the two actually disagree, so a stock device reads unchanged.
        // Rounded to whole GB — the header is a one-line summary, and the exact
        // figure ("255.84 GB") belongs in the General tab, not here.
        var cap = capacityBytes > 0
            ? String(format: "%.0f GB", Double(capacityBytes) / 1_000_000_000)
            : String(format: "%.0f GB", info.capacityGB)
        if hasNonStockDrive {
            cap += String(format: " (%.0f GB stock)", info.capacityGB)
        }
        let pieces = [
            info.modelName,
            info.generation,
            cap,
            "\(info.trackCount) track\(info.trackCount == 1 ? "" : "s")",
            "\(info.playlistCount) playlist\(info.playlistCount == 1 ? "" : "s")",
        ].filter { !$0.isEmpty }
        return pieces.joined(separator: " · ")
    }

    /// Which iPod's ticks and quality setting the tabs are showing.
    ///
    /// Not decoration. Selection is per-device, so with nothing plugged in the
    /// tabs edit the default profile — and a user who ticks fifty albums
    /// unplugged, then connects their iPod, will find those ticks "missing".
    /// Nothing was lost, which makes it more confusing rather than less, so the
    /// answer has to be on screen the whole time.
    private var editingBadge: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(profile.isDefault ? "Default settings" : "Editing \(profile.displayName)")
                .font(.caption)
                .fontWeight(.medium)
            Text(profile.manageManually
                 ? "Managed by hand \u{00B7} \(profile.ceiling.shortTitle)"
                 : profile.ceiling.shortTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(helpText)
    }

    private var helpText: String {
        if profile.isDefault {
            return "No iPod is connected, so the tabs below show the settings and selection used for a new iPod. Connect one to edit its own."
        }
        if profile.manageManually {
            return "This iPod is managed by hand: you add and remove music yourself in the Manual tab, and it never syncs with your library. The quality setting still applies to music you add."
        }
        return "Ticks and quality below apply to this iPod. Each iPod keeps its own."
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .noIPod:
            EmptyView()
        case .opening:
            ProgressView().controlSize(.small)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.iconOnly)
                .imageScale(.large)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
        }
    }
}

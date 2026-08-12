import SwiftUI

struct HeaderView: View {
    let info: DeviceInfo?
    let status: IPodController.Status
    /// Installed capacity in bytes, and whether it differs from what the model
    /// shipped with. Both come from `IPodController`, which is the only place
    /// that sees the model table and the mounted volume together.
    let capacityBytes: UInt64
    let hasNonStockDrive: Bool
    let onEject: () -> Void

    var body: some View {
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
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var primaryLine: String {
        info?.displayName ?? "No iPod connected"
    }

    private var secondaryLine: String {
        guard let info else {
            switch status {
            case .opening: return "Opening…"
            case .error(let m): return m
            default: return "Connect an iPod via USB to begin"
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
        let pieces = [info.modelName, info.generation, cap, "\(info.trackCount) tracks"]
            .filter { !$0.isEmpty }
        return pieces.joined(separator: " · ")
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

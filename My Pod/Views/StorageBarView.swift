import SwiftUI

struct StorageBarView: View {
    let breakdown: StorageBreakdown
    let canSync: Bool
    let onSync: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let total = max(UInt64(1), breakdown.capacity)
                let musicW = width * fraction(breakdown.music, of: total)
                let otherW = width * fraction(breakdown.other, of: total)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: musicW)
                    Rectangle()
                        .fill(Color.gray.opacity(0.6))
                        .frame(width: otherW)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 12)

            HStack(spacing: 16) {
                LegendDot(color: .accentColor, label: "Music", value: format(breakdown.music))
                LegendDot(color: .gray.opacity(0.6), label: "Other", value: format(breakdown.other))
                LegendDot(color: .secondary.opacity(0.4), label: "Free", value: format(breakdown.free))
                Spacer()
                if breakdown.capacity > 0 {
                    Text("\(format(breakdown.capacity)) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Capacity of the mounted volume. On an iPod whose drive has been replaced this is larger than the model's stock size — see the General tab.")
                }
                Button(action: onSync) {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canSync)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func fraction(_ value: UInt64, of total: UInt64) -> CGFloat {
        CGFloat(min(value, total)) / CGFloat(total)
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).fontWeight(.medium)
            Text(value).font(.caption).foregroundStyle(.secondary)
        }
    }
}

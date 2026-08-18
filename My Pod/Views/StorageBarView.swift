import SwiftUI

struct StorageBarView: View {
    let breakdown: StorageBreakdown
    /// What the current selection would add and free. `.init()` when no iPod is
    /// attached, which renders the plain bar.
    var pending: MusicLibraryStore.PendingBytes = .init()
    let canSync: Bool
    /// What the primary action is called. A manually managed iPod has no mirror
    /// to run, but it does have a queue to commit, and putting that anywhere
    /// other than the button everyone already reaches for would be its own kind
    /// of surprise.
    let syncTitle: String
    let onSync: () -> Void

    /// Space the additions have to fit into. Removals run before additions, so
    /// what they free counts toward it.
    private var available: UInt64 { breakdown.free &+ pending.removing }
    private var overBytes: UInt64 { pending.adding > available ? pending.adding &- available : 0 }
    private var isOver: Bool { overBytes > 0 }

    /// Music staying put — what's on the device now, less what's leaving.
    private var musicStaying: UInt64 {
        breakdown.music > pending.removing ? breakdown.music &- pending.removing : 0
    }

    private var freeAfter: UInt64 {
        available > pending.adding ? available &- pending.adding : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar
            legend
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Bar

    private var bar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(UInt64(1), breakdown.capacity)

            // Fixed order — music, removing, adding, other, free — so the two
            // pending segments always meet in the middle and can be compared by
            // width alone.
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: width * fraction(musicStaying, of: total))

                if pending.removing > 0 {
                    // Inverse of the adding treatment: the ground is already the
                    // free colour and the music is the ghost, so the segment
                    // reads as emptying rather than filling.
                    HatchedSegment(
                        base: Color.secondary.opacity(0.15),
                        stripe: Color.accentColor.opacity(0.30),
                        leaning: .back
                    )
                    .frame(width: width * fraction(pending.removing, of: total))
                }

                if pending.adding > 0 {
                    HatchedSegment(
                        base: (isOver ? Color.red : Color.accentColor).opacity(0.22),
                        stripe: (isOver ? Color.red : Color.accentColor).opacity(0.85),
                        leaning: .forward
                    )
                    // Clamped: a segment running past the end would have to be
                    // scaled to something, and nothing sensible is available.
                    // The bar carries "it doesn't fit"; the legend carries by
                    // how much.
                    .frame(width: width * fraction(min(pending.adding, available), of: total))
                }

                Rectangle()
                    .fill(Color.gray.opacity(0.6))
                    .frame(width: width * fraction(breakdown.other, of: total))

                Rectangle()
                    .fill(Color.secondary.opacity(0.15))

                if isOver {
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                if isOver {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.red, lineWidth: 1.5)
                }
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.18), value: pending)
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 16) {
            LegendDot(color: .accentColor, label: "Music", value: format(musicStaying))

            if pending.removing > 0 {
                LegendDot(
                    color: .secondary.opacity(0.15),
                    ringed: true,
                    label: "Removing",
                    value: format(pending.removing)
                )
            }
            if pending.adding > 0 {
                LegendDot(
                    color: isOver ? .red.opacity(0.5) : .accentColor.opacity(0.5),
                    label: "Adding",
                    value: format(pending.adding)
                )
            }

            LegendDot(color: .gray.opacity(0.6), label: "Other", value: format(breakdown.other))

            if isOver {
                LegendDot(color: .red, label: "Over by", value: format(overBytes), tint: .red)
                    .help("The selection is bigger than the iPod. Uncheck some music, or switch to selected music in General.")
            } else {
                LegendDot(
                    color: .secondary.opacity(0.4),
                    label: pending.isEmpty ? "Free" : "Free after",
                    value: format(pending.isEmpty ? breakdown.free : freeAfter)
                )
            }

            Spacer()

            if breakdown.capacity > 0 {
                Text("\(format(breakdown.capacity)) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Capacity of the mounted volume. On an iPod whose drive has been replaced this is larger than the model's stock size — see the General tab.")
            }
            Button(action: onSync) {
                Label(syncTitle, systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!canSync)
        }
    }

    private func fraction(_ value: UInt64, of total: UInt64) -> CGFloat {
        CGFloat(min(value, total)) / CGFloat(total)
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}

/// A diagonally striped fill. Stripe direction distinguishes arriving from
/// departing without relying on colour, and stripe weight says which way the
/// space is moving — the arriving block is dense, the departing one faint.
private struct HatchedSegment: View {
    enum Lean { case forward, back }

    let base: Color
    let stripe: Color
    let leaning: Lean

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            let spacing: CGFloat = 5
            let reach = size.width + size.height
            var path = Path()
            var x = -size.height
            while x < reach {
                let top = leaning == .forward ? x + size.height : x
                let bottom = leaning == .forward ? x : x + size.height
                path.move(to: CGPoint(x: top, y: 0))
                path.addLine(to: CGPoint(x: bottom, y: size.height))
                x += spacing
            }
            context.stroke(path, with: .color(stripe), lineWidth: 2)
        }
    }
}

private struct LegendDot: View {
    let color: Color
    var ringed: Bool = false
    let label: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .overlay {
                    if ringed {
                        Circle().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                    }
                }
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        }
    }
}

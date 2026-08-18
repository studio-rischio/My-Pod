import SwiftUI

/// Explains the two management models at the moment someone switches between
/// them.
///
/// This exists because the modes differ in what happens to music that is
/// *already* on the iPod, and that difference is invisible until a sync runs.
/// Left as a silent rule, going back to library mode strands music at some
/// later moment, on someone with no idea a rule changed. A deliberate flip is
/// the one point where the app can state the consequence and be believed — so
/// it explains both sides rather than only warning about one.
struct ModeChangeSheet: View {
    /// The mode being switched *to*.
    let target: Bool
    let deviceName: String
    /// Tracks a sync would remove. Only meaningful going back to library mode.
    let strandedCount: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                modeCard(
                    title: "Library mode",
                    detail: "This iPod mirrors your music library. Syncing adds what you've ticked in the Music and Playlists tabs, and removes what you haven't.",
                    systemImage: "arrow.triangle.2.circlepath",
                    selected: !target
                )
                modeCard(
                    title: "Manual mode",
                    detail: "You add and remove music yourself in the Manual tab. This iPod never syncs, so music on it is never removed behind your back — including music that isn't in your library at all.",
                    systemImage: "hand.draw",
                    selected: target
                )

                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    // Destructive only in the direction that can strand music.
                    .tint(strandedCount > 0 && !target ? .red : .accentColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
    }

    private func modeCard(title: String, detail: String, systemImage: String, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if selected {
                        Text("choosing this")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.35) : Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private var title: String {
        target
            ? "Manage \u{201C}\(deviceName)\u{201D} by hand?"
            : "Sync \u{201C}\(deviceName)\u{201D} with your library?"
    }

    private var confirmTitle: String {
        target ? "Manage by Hand" : "Sync With Library"
    }

    /// Only one direction can lose anything, and only when music is actually
    /// stranded — so this stays silent rather than warning reflexively.
    private var warning: String? {
        guard !target, strandedCount > 0 else { return nil }
        let s = strandedCount == 1
        return "\(strandedCount) track\(s ? "" : "s") on this iPod \(s ? "isn't" : "aren't") in your library selection. The next sync will remove \(s ? "it" : "them")."
    }

    private var footnote: String {
        target
            ? "Nothing is removed by switching, and the music you've ticked is remembered — switch back and it returns. Only this iPod is affected."
            : "Your music library and its files aren't touched either way. Only this iPod is affected."
    }
}

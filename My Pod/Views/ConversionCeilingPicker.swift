import SwiftUI

/// Picks how tightly music is re-encoded before it's synced.
///
/// Shared by the General tab (where it sets the connected iPod's quality) and
/// Settings (where it sets the default a new iPod starts at), so the two can't
/// drift apart in wording or in what they warn about.
///
/// The looser levels are a considered risk, not a hidden power feature, so the
/// UI says which hardware each was verified on and what going wrong looks like.
/// A user who can't tell whether their iPod is affected should be able to read
/// this and conclude "leave it alone", which is why the default sits first and
/// the warning is attached to the choice rather than buried in a help tag.
struct ConversionCeilingPicker: View {
    /// What the change applies to, in the user's terms — an iPod's name, or the
    /// default. Used in the headline and the confirmation.
    let subject: String
    let current: ConversionCeiling
    let onChange: (ConversionCeiling) -> Void

    /// What the picker shows. Only written back once the user has confirmed, so
    /// cancelling a change snaps the radio button back.
    @State private var selection: ConversionCeiling
    /// The change awaiting confirmation, if any.
    @State private var proposed: ConversionCeiling?

    init(subject: String, current: ConversionCeiling, onChange: @escaping (ConversionCeiling) -> Void) {
        self.subject = subject
        self.current = current
        self.onChange = onChange
        _selection = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Quality ceiling")
                    .font(.headline)

                Text("Click-wheel iPods play a narrower range of audio than their specs suggest, and give no error when a file is out of range — the track just skips. Music above this limit is converted down to it. Music below it is left exactly as it is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: $selection) {
                    ForEach(ConversionCeiling.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(selection.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if selection != .aac44 {
                Label(
                    "If tracks start skipping or refusing to play, drop back to 44.1 kHz AAC and sync again. 96 and 192 kHz music is converted whatever you pick — those don't play on any click-wheel iPod.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Label(
                "\(selection.sizeNote) Each iPod keeps its own setting, and converted music is kept separately for each one in use. Your original music is never touched.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: current) { _, new in
            // Somewhere else changed it — a different iPod was plugged in, or
            // Settings moved the default. Follow, don't argue.
            if proposed == nil { selection = new }
        }
        .onChange(of: selection) { old, new in
            guard new != current else { return }
            proposed = new
            // Snap back for now; `apply` puts it where it belongs on confirm.
            selection = old
        }
        .confirmationDialog(
            "Change \(subject) to \(proposed?.title ?? "")?",
            isPresented: Binding(get: { proposed != nil }, set: { if !$0 { proposed = nil } }),
            titleVisibility: .visible
        ) {
            Button("Change and Re-encode") { apply() }
            Button("Cancel", role: .cancel) { proposed = nil }
        } message: {
            Text("Music that needs converting will be encoded again at the new setting during the next sync, which takes a few seconds per track. Converted files for a setting no iPod is using any more are deleted. Your original files aren't touched.")
        }
    }

    private func apply() {
        guard let target = proposed else { return }
        proposed = nil
        selection = target
        onChange(target)
    }
}

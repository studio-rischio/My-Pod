import SwiftUI

/// Asks which iPod is attached, then writes `iPod_Control/Device/SysInfo`.
///
/// The list comes from libgpod's own compiled-in model table rather than a
/// copy — whatever it will accept in `ModelNumStr` is exactly what's offered
/// here, so a choice can't fail to resolve afterwards.
struct IdentifySheet: View {
    let controller: IPodController
    /// The mounted volume's real capacity. Only ever a hint: a re-drived iPod —
    /// a CF card or an SD adapter, which is common on the devices this feature
    /// is for — matches no stock capacity at all.
    let capacityBytes: UInt64
    @Environment(\.dismiss) private var dismiss

    @State private var models: [IPodModel] = []
    @State private var findings: DeviceIdentification.Findings = .none
    @State private var generation: String = ""
    @State private var selectedModelNumber: IPodModel.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            picker
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .task { await load() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identify iPod")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Restoring an iPod through Finder or Windows no longer writes the small file that records which model it is. Without it, My Pod can copy your music but never your album art.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let suggested = findings.suggested {
                Label(
                    "This looks like a \(suggested.modelName) — \(suggested.generation), from its serial number.",
                    systemImage: "sparkles"
                )
                .font(.callout)
            }
        }
        .padding(16)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Which iPod is this?", selection: $generation) {
                ForEach(generations, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: generation) { _, _ in
                // Don't carry a selection across generations — the model
                // number would still be from the old one.
                if selectedModel?.generation != generation { selectedModelNumber = nil }
            }

            List(modelsInGeneration, selection: $selectedModelNumber) { model in
                HStack {
                    Text(model.rowLabel)
                    if matchesInstalledCapacity(model) {
                        Text("matches this iPod's size")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(model.id)
            }
            .listStyle(.bordered)

            artworkNote
        }
        .padding(16)
    }

    /// Says up front whether the choice will actually get the user artwork.
    /// A 4th-generation iPod or a mini has no cover art at any identity, and
    /// letting someone write `SysInfo` expecting art they'll never see would
    /// just be the original bug wearing a different hat.
    @ViewBuilder
    private var artworkNote: some View {
        if let model = selectedModel {
            if model.supportsArtwork {
                Label("Album art works on this model.", systemImage: "photo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "This model came out before iPods could display album art, so identifying it won't bring artwork — but it will still show the right name and capacity.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Pick the colour and size that match your iPod. The size is what it shipped with — if you've replaced the drive, go by colour.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            // Says the stakes out loud, in both directions: it writes to the
            // iPod, and getting it wrong costs nothing.
            Text(findings.firewireGUID == nil
                 ? "Writes one small file to the iPod. Pick again any time to change it."
                 : "Writes one small file to the iPod, including its serial number. Pick again any time to change it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Identify") {
                guard let model = selectedModel else { return }
                controller.identify(as: model, firewireGUID: findings.firewireGUID)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedModel == nil)
        }
        .padding(16)
    }

    // MARK: - Data

    private var generations: [String] {
        var seen = Set<String>()
        // Table order, not alphabetical — it runs oldest to newest, which is
        // how someone scanning for "Nano (2nd Gen.)" expects to find it.
        return models.compactMap { seen.insert($0.generation).inserted ? $0.generation : nil }
    }

    private var modelsInGeneration: [IPodModel] {
        models.filter { $0.generation == generation }
    }

    private var selectedModel: IPodModel? {
        models.first { $0.id == selectedModelNumber }
    }

    /// Within 25% of the model's stock size — the same loose band
    /// `IPodController.hasNonStockDrive` uses, because a stock drive's
    /// formatted capacity always lands somewhat under its marketing number.
    private func matchesInstalledCapacity(_ model: IPodModel) -> Bool {
        guard capacityBytes > 0, model.capacityGB > 0 else { return false }
        let stock = model.capacityGB * 1_000_000_000
        return abs(Double(capacityBytes) - stock) / stock <= 0.25
    }

    private func load() async {
        let loaded = IPodModel.all()
        let found = controller.identificationFindings(models: loaded)
        models = loaded
        findings = found
        if let suggested = found.suggested {
            generation = suggested.generation
            selectedModelNumber = suggested.id
        } else if generation.isEmpty {
            generation = loaded.first?.generation ?? ""
        }
    }
}

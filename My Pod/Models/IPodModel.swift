import Foundation

/// One row of libgpod's compiled-in model table.
///
/// `nonisolated` because the table is read off the main actor when identifying
/// a device — it's static data with no device attached.
nonisolated struct IPodModel: Sendable, Identifiable, Hashable {
    /// What goes in `SysInfo`'s `ModelNumStr`, e.g. `A726`.
    var modelNumber: String
    /// libgpod's name, which folds colour in: "Nano (Red)", "Video (White)".
    var modelName: String
    /// "Nano (2nd Gen.)". Not unique — all three iPod classic generations
    /// share the string "Classic", which is fine for grouping because they
    /// share artwork behaviour too, and capacity tells them apart in the list.
    var generation: String
    /// The capacity this model *shipped* with. A re-drived iPod won't match
    /// any of them, which is why capacity narrows the list but never filters it.
    var capacityGB: Double
    /// Whether picking this model gets the user cover art. False for iPod
    /// 1G–4G, mini and shuffle, which predate artwork entirely.
    var supportsArtwork: Bool

    var id: String { modelNumber }

    /// "Nano (Red)" → "Red". Nil for the models libgpod names without one
    /// ("Grayscale", "Color", "Video U2").
    var colorName: String? {
        guard let open = modelName.firstIndex(of: "("),
              let close = modelName.lastIndex(of: ")"),
              open < close else { return nil }
        let inner = modelName[modelName.index(after: open)..<close]
        return inner.isEmpty ? nil : String(inner)
    }

    /// How a row reads in the picker: "Red · 8 GB", or "8 GB" when the model
    /// carries no colour.
    var rowLabel: String {
        let size = capacityGB >= 1
            ? String(format: "%.0f GB", capacityGB)
            : String(format: "%.0f MB", capacityGB * 1000)
        if let color = colorName { return "\(color) · \(size)" }
        return size
    }

    /// Load the whole table. Static data, so this is cheap and repeatable.
    static func all() -> [IPodModel] {
        var count: Int32 = 0
        guard let raw = ipod_list_models(&count), count > 0 else { return [] }
        defer { ipod_free_models(raw, count) }
        return (0..<Int(count)).map { i in
            let m = raw[i]
            return IPodModel(
                modelNumber: m.model_number.flatMap { String(cString: $0) } ?? "",
                modelName: m.model_name.flatMap { String(cString: $0) } ?? "",
                generation: m.generation.flatMap { String(cString: $0) } ?? "",
                capacityGB: m.capacity_gb,
                supportsArtwork: m.supports_artwork != 0
            )
        }
    }
}

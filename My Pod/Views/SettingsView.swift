import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ConversionSettingsView()
                .tabItem { Label("Conversion", systemImage: "waveform") }
            CacheSettingsView()
                .tabItem { Label("Cache", systemImage: "internaldrive") }
        }
        .frame(width: 520, height: 520)
        .scenePadding()
    }
}

/// The quality a *new* iPod starts at, plus the list of iPods already known.
///
/// A connected iPod's own quality is set in the General tab instead — this is a
/// separate `Settings {}` scene with no reference to the main window's state, so
/// a per-device control here would be inert whenever nothing is plugged in,
/// which is a bad settings pane. What lives here is the value that has meaning
/// without a device attached.
private struct ConversionSettingsView: View {
    @State private var profiles = DeviceProfileStore.shared
    @State private var forgetting: DeviceProfile?

    private var libraryRoot: URL? {
        UserDefaults.standard.string(forKey: "MyPod.libraryRoot").map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ConversionCeilingPicker(
                    subject: "the default quality",
                    current: ConversionCeiling.current
                ) { target in
                    profiles.setCeiling(target, for: DeviceProfile.defaultKey, libraryRoot: libraryRoot)
                    // Nothing is rescanned any more — which tracks convert is
                    // decided at sync time now — but the cache just changed
                    // shape, so size estimates are stale.
                    NotificationCenter.default.post(name: CacheLocation.didChange, object: nil)
                }

                Text("Used when no iPod is connected, and as the starting point for an iPod My Pod hasn't seen before. Each iPod's own setting lives in the General tab while it's plugged in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !profiles.devices.isEmpty {
                    Divider()
                    knownDevices
                }
            }
            .padding(.vertical, 4)
        }
        .confirmationDialog(
            "Forget \"\(forgetting?.displayName ?? "")\"?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let target = forgetting {
                    profiles.forget(target.key, libraryRoot: libraryRoot)
                }
                forgetting = nil
            }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: {
            Text("Its quality setting and its list of ticked music and playlists are deleted. Nothing on the iPod itself changes — but the next time you connect it, it starts from the default settings again.")
        }
    }

    private var knownDevices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iPods My Pod knows")
                .font(.headline)

            Text("Each keeps its own quality setting and its own list of ticked music, so a small iPod doesn't have to hold what a large one does.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(profiles.devices) { device in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.displayName).fontWeight(.medium)
                        Text([device.modelName, device.ceiling.shortTitle]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(lastSeen(device.lastSeen))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Forget…") { forgetting = device }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func lastSeen(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct CacheSettingsView: View {
    @State private var location: CacheLocation = .current
    @State private var report: CacheInventory.Report?
    @State private var scanning = false
    @State private var confirming: CacheLocation?
    @State private var profiles = DeviceProfileStore.shared

    /// Read straight from defaults rather than threaded down from ContentView —
    /// Settings is its own scene and has no access to the main window's state.
    private var libraryRoot: URL? {
        UserDefaults.standard.string(forKey: "MyPod.libraryRoot").map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                locationSection
                Divider()
                storedSection
            }
            .padding(.vertical, 4)
        }
        .task { await refresh() }
        .onChange(of: location) { _, new in
            CacheLocation.setCurrent(new)
            Task { await refresh() }
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Converted Files", role: .destructive) {
                if let target = confirming { clear(target) }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("The originals in your music library aren't touched. Anything you sync afterwards will be converted again, which takes a few seconds per track.")
        }
    }

    // MARK: - Where

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where converted files are kept")
                .font(.headline)

            Text("Music the iPod can't play — FLAC, OGG and the rest — is converted and kept so it's only ever encoded once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $location) {
                Text("In Application Support").tag(CacheLocation.applicationSupport)
                Text("Beside the music, in hidden .mypod folders").tag(CacheLocation.besideMusic)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(rationale)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Label(
                "Changing this doesn't move anything. Music already converted stays where it is, and is converted again into the new location the first time it's needed.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rationale: String {
        switch location {
        case .applicationSupport:
            "Your music folders are never written to. Best if your library is on a network share, is read-only, or is synced by something like Dropbox or iCloud. Moving or renaming your library means converting again."
        case .besideMusic:
            "Converted files travel with the music, so renaming folders or moving the library keeps them, and deleting an album removes its cache too. In exchange, My Pod writes hidden folders into your library."
        }
    }

    // MARK: - What's stored

    private var storedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Stored converted files")
                    .font(.headline)
                Spacer()
                if scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Recalculate") { Task { await refresh() } }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }

            storeRow(
                .applicationSupport,
                title: "Application Support",
                detail: CacheLocation.appSupportRoot.path
            )
            storeRow(
                .besideMusic,
                title: "In your music library",
                detail: libraryRoot.map { "\($0.path) — hidden .mypod folders" }
                    ?? "No music library chosen"
            )

            if let report, report.besideMusicBytes > 0, location == .applicationSupport {
                Label(
                    "These are left over from before you switched. Deleting them is safe — nothing uses them now.",
                    systemImage: "arrow.uturn.left.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let report, !report.byCeiling.isEmpty {
                Divider().padding(.vertical, 4)
                byQualitySection(report)
            }
        }
    }

    /// What each quality setting costs, and which iPods are keeping it alive.
    ///
    /// Converted music is kept per setting so two iPods at different qualities
    /// don't re-encode the library at each other every time you swap. The
    /// arithmetic is worth showing: lossless runs roughly 3× AAC, so two iPods
    /// can cost far more than one, and a number with no explanation reads as a
    /// bug.
    @ViewBuilder
    private func byQualitySection(_ report: CacheInventory.Report) -> some View {
        let inUse = profiles.ceilingsInUse
        let unused = report.unusedBytes(inUse: inUse)

        VStack(alignment: .leading, spacing: 8) {
            Text("By quality setting")
                .font(.callout)
                .fontWeight(.medium)

            ForEach(ConversionCeiling.allCases.filter { report.byCeiling[$0] != nil }) { ceiling in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ceiling.shortTitle)
                    if !inUse.contains(ceiling) {
                        Text("no iPod uses this")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(format(report.byCeiling[ceiling] ?? 0))
                        .monospacedDigit()
                        .foregroundStyle(inUse.contains(ceiling) ? .primary : .secondary)
                }
                .font(.callout)
            }

            if unused > 0 {
                HStack {
                    Text("\(format(unused)) is kept for settings no iPod is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Delete Unused") {
                        Log.ui.info("user cleared unused-quality caches")
                        CacheInventory.collectUnused(inUse: inUse, libraryRoot: libraryRoot)
                        NotificationCenter.default.post(name: CacheLocation.didChange, object: nil)
                        Task { await refresh() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func storeRow(_ target: CacheLocation, title: String, detail: String) -> some View {
        let bytes = report?.bytes(for: target)
        let count = target == .applicationSupport ? report?.appSupportFiles : report?.besideMusicFiles

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if target == location {
                        Text("In use")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(bytes.map(format) ?? "—")
                    .monospacedDigit()
                    .fontWeight(.medium)
                if let count, count > 0 {
                    Text("\(count) file\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Button("Clear…") { confirming = target }
                .disabled((bytes ?? 0) == 0)
        }
        .padding(.vertical, 2)
    }

    private var confirmTitle: String {
        switch confirming {
        case .applicationSupport: "Delete converted files in Application Support?"
        case .besideMusic: "Delete the .mypod folders in your music library?"
        case nil: ""
        }
    }

    // MARK: - Actions

    private func clear(_ target: CacheLocation) {
        Log.ui.info("user cleared cache: \(target.rawValue)")
        switch target {
        case .applicationSupport:
            CacheInventory.clearAppSupport()
        case .besideMusic:
            CacheInventory.clearBesideMusic(libraryRoot: libraryRoot)
        }
        // What's cached just changed, so anything derived from it is stale.
        NotificationCenter.default.post(name: CacheLocation.didChange, object: nil)
        Task { await refresh() }
    }

    private func refresh() async {
        scanning = true
        report = await CacheInventory.scan(libraryRoot: libraryRoot)
        scanning = false
    }

    private func format(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "None" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}

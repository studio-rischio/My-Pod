import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            CacheSettingsView()
                .tabItem { Label("Cache", systemImage: "internaldrive") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct CacheSettingsView: View {
    @State private var location: CacheLocation = .current
    @State private var report: CacheInventory.Report?
    @State private var scanning = false
    @State private var confirming: CacheLocation?

    /// Read straight from defaults rather than threaded down from ContentView —
    /// Settings is its own scene and has no access to the main window's state.
    private var libraryRoot: URL? {
        UserDefaults.standard.string(forKey: "MyPod.libraryRoot").map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            locationSection
            Divider()
            storedSection
        }
        .padding(.vertical, 4)
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

            Text("Music the iPod can't play — FLAC, OGG and the rest — is converted to AAC and kept so it's only ever encoded once.")
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

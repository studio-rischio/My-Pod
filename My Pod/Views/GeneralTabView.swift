import SwiftUI

struct GeneralTabView: View {
    @Bindable var controller: IPodController
    @Bindable var libraryStore: MusicLibraryStore
    @Bindable var playlistStore: PlaylistStore
    @State private var showResetConfirm = false
    @State private var showQualitySheet = false
    @State private var showModeSheet = false
    @State private var proposedManual = false
    @State private var strandedCount = 0
    @State private var profiles = DeviceProfileStore.shared
    @State private var artworkResendQueued = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Device state first, then Library. Library is deliberately
                // outside the connected/disconnected branch: choosing folders
                // is the first thing a new user does, and requiring an iPod to
                // be plugged in before the app will let them do it is backwards.
                deviceSection(controller.deviceInfo)

                librarySection

                if controller.deviceInfo != nil {
                    dangerZone
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    /// The device facts the header bar doesn't already carry.
    ///
    /// Name, model, generation, capacity, track and playlist counts all live in
    /// the header, so repeating them here was just noise taking up height. What's
    /// left is the identity and location — the two things you'd actually come to
    /// this box to read or copy rather than glance at.
    ///
    /// Rendered identically whether or not an iPod is attached, with placeholders
    /// standing in. That's the point: the box keeps its height, so connecting a
    /// device doesn't shove the rest of the tab down the page. The header is
    /// already saying "No iPod connected" loudly enough that this doesn't need
    /// to as well.
    private func deviceSection(_ info: DeviceInfo?) -> some View {
        GroupBox("Device") {
            VStack(alignment: .leading, spacing: 8) {
                infoRow("UUID", info?.uuid ?? placeholder)
                    .textSelection(.enabled)
                    .help("The iPod's FireWire GUID. My Pod uses it to recognise this device and remember its settings.")
                infoRow("Volume", info?.mountpoint.path ?? placeholder)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// An em dash rather than "Not connected" in every row: the header says that
    /// once, and three copies of it reads like an error.
    private var placeholder: String { "—" }

    private var isManual: Bool { profiles.active.manageManually }

    /// Which of the two models this iPod uses.
    ///
    /// A switch rather than a button, because these are two standing states and
    /// neither is an "action" — the picker shows you which one you're in without
    /// having to read a sentence. Flipping it opens an explanation rather than
    /// applying immediately: the two modes differ in what happens to music you
    /// already have, which is not something to discover afterwards.
    private var managementRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Management")
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: managementBinding) {
                    Text("Library mode").tag(false)
                    Text("Manual mode").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(isManual
                     ? "You add and remove music yourself in the Manual tab. This iPod never syncs, so nothing is removed behind your back."
                     : "Syncing mirrors your library onto this iPod: ticked music is added, unticked music is removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showModeSheet) {
            ModeChangeSheet(
                target: proposedManual,
                deviceName: profiles.active.displayName,
                strandedCount: strandedCount,
                onConfirm: {
                    profiles.setManageManually(proposedManual, for: profiles.active.key)
                    showModeSheet = false
                },
                onCancel: { showModeSheet = false }
            )
        }
    }

    /// Intercepts the picker: reads the real state, but a write only *proposes*
    /// the change and opens the explanation. The radio snaps back until the
    /// sheet confirms.
    private var managementBinding: Binding<Bool> {
        Binding(
            get: { profiles.active.manageManually },
            set: { wanted in
                guard wanted != profiles.active.manageManually else { return }
                proposedManual = wanted
                // Only the destructive direction needs a count, and it has to be
                // taken now, while the selection still means something.
                strandedCount = wanted ? 0 : strandedTrackCount()
                showModeSheet = true
            }
        )
    }

    /// Tracks the device holds that a sync would remove — everything on it that
    /// isn't in this profile's selection. Counted at the moment of asking rather
    /// than tracked, because it's only ever needed for this one sentence.
    private func strandedTrackCount() -> Int {
        guard let snapshot = controller.snapshot else { return 0 }
        if libraryStore.syncMode == .entireLibrary {
            var keys: Set<TrackKey> = []
            for artist in libraryStore.library.artists {
                for album in artist.albums {
                    for track in album.tracks { keys.insert(TrackKey(library: track)) }
                }
            }
            return snapshot.bytesByTrackKey.keys.filter { !keys.contains($0) }.count
        }
        let selected = libraryStore.effectiveSelectedPaths
        var keys: Set<TrackKey> = []
        for artist in libraryStore.library.artists {
            for album in artist.albums {
                for track in album.tracks where selected.contains(track.url.path) {
                    keys.insert(TrackKey(library: track))
                }
            }
        }
        return snapshot.bytesByTrackKey.keys.filter { !keys.contains($0) }.count
    }

    /// This iPod's quality ceiling.
    ///
    /// Here rather than in Settings because it's a property of the device, like
    /// the rows above it — Settings is a separate scene that can't see the
    /// connected iPod, so the control would be inert there whenever nothing is
    /// plugged in. Settings keeps the default a new iPod starts at.
    private var qualityRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Quality")
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(profiles.active.ceiling.title)
                Text("Music above this is converted down to it. Each iPod keeps its own setting.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Change…") { showQualitySheet = true }
        }
        .sheet(isPresented: $showQualitySheet) {
            VStack(alignment: .leading, spacing: 16) {
                ConversionCeilingPicker(
                    subject: "the quality for “\(profiles.active.displayName)”",
                    current: profiles.active.ceiling
                ) { target in
                    profiles.setCeiling(target, for: profiles.active.key, libraryRoot: libraryStore.libraryRoot)
                    // Sizes and "needs converting" both moved. No rescan — the
                    // scan records what files *are*, not what happens to them.
                    NotificationCenter.default.post(name: CacheLocation.didChange, object: nil)
                }
                HStack {
                    Spacer()
                    Button("Done") { showQualitySheet = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 520)
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        GroupBox("Library") {
            VStack(alignment: .leading, spacing: 12) {
                pathRow(
                    label: "Music",
                    path: libraryStore.libraryRoot?.path,
                    placeholder: "No folder chosen",
                    help: "A Plex-structured folder: Library/Artist/Album/Track."
                ) {
                    if let url = FolderPicker.chooseLibraryRoot() {
                        libraryStore.chooseRoot(url)
                    }
                }

                pathRow(
                    label: "Playlists",
                    path: playlistStore.directory.path,
                    placeholder: "",
                    help: "The folder My Pod reads .m3u playlists from."
                ) {
                    if let url = FolderPicker.choosePlaylistFolder() {
                        playlistStore.chooseDirectory(url)
                    }
                }

                if controller.deviceInfo != nil {
                    Divider()
                    managementRow
                }

                if controller.deviceInfo?.supportsArtwork == true {
                    Divider()
                    artworkRow
                }

                // The iTunes sync radio only means something for an iPod that
                // mirrors the library. A manually managed one has no selection
                // for it to govern, so it goes rather than sitting inert.
                if !isManual {
                    Divider()
                    syncModeRow
                }

                Divider()

                Text("Conversion")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if controller.deviceInfo != nil {
                    qualityRow
                }
                ConversionSectionView(store: libraryStore)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The iTunes sync radio. Kept in the same order and near enough the same
    /// wording, because it's the control anyone who synced an iPod before 2019
    /// will be looking for.
    @ViewBuilder
    private var syncModeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Sync")
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $libraryStore.syncMode) {
                    Text("Entire music library").tag(MusicLibraryStore.SyncMode.entireLibrary)
                    Text("Selected playlists, artists and albums").tag(MusicLibraryStore.SyncMode.selected)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(libraryStore.syncMode == .entireLibrary
                     ? "Everything in your library syncs, and the checkboxes in the Music and Playlists tabs are turned off."
                     : "Check what you want in the Music and Playlists tabs. Checking a playlist also syncs the tracks it contains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One folder setting: label, current path, and the button that changes it.
    private func pathRow(
        label: String,
        path: String?,
        placeholder: String,
        help: String,
        change: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            if let path {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(path == nil ? "Choose…" : "Change…", action: change)
        }
        .help(help)
    }

    /// Forces every album's cover to be sent again on the next sync.
    ///
    /// The app resends automatically when an iPod goes from unable to receive
    /// artwork to able, but that only fires for a transition it *saw*. Anyone
    /// who fixed their `SysInfo` by hand before installing this version — which
    /// is what the workaround in issue #3 asks for — was already identified by
    /// the time we first looked, so nothing looked like a transition and their
    /// existing albums would stay bare with no way to say otherwise. Resetting
    /// the iPod would work and costs hours of re-copying; this costs a database
    /// edit, since libgpod renders thumbnails from covers already on disk.
    private var artworkRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Album art")
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Button(artworkResendQueued ? "Will send on next sync" : "Send All Again") {
                    Log.ui.info("user clicked Send All Album Art Again")
                    ArtworkSync.resendEverything(to: profiles.active)
                    artworkResendQueued = true
                }
                .disabled(artworkResendQueued || controller.status != .ready)

                Text("Sends every album's cover to this iPod again, whether or not it already has one. No music is copied. Use this if artwork never arrived — after fixing the iPod's model by hand, say.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        // A different iPod has its own answer, so the button un-latches.
        .onChange(of: profiles.active.key) { _, _ in artworkResendQueued = false }
    }

    // MARK: - Danger zone

    private var dangerZone: some View {
        GroupBox("Danger Zone") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset iPod").fontWeight(.medium)
                    Text("Wipes all music files, artwork, and the database. The iPod ends up empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Reset…") {
                    Log.ui.info("user clicked Reset iPod")
                    showResetConfirm = true
                }
                    .tint(.red)
                    .disabled(controller.status != .ready)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Reset iPod entirely?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset iPod", role: .destructive) {
                Log.ui.info("user confirmed Reset iPod")
                controller.fullReset()
            }
            Button("Cancel", role: .cancel) {
                Log.ui.info("user cancelled Reset iPod")
            }
        } message: {
            Text("All music, artwork, and database files will be deleted. This cannot be undone.")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

import SwiftUI

struct ContentView: View {
    @State private var controller = IPodController()
    @State private var libraryStore = MusicLibraryStore()
    @State private var playlistStore = PlaylistStore()
    @State private var syncEngine = SyncEngine()
    @State private var showSyncSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                info: controller.deviceInfo,
                status: controller.status,
                capacityBytes: controller.effectiveCapacityBytes,
                hasNonStockDrive: controller.hasNonStockDrive,
                onEject: { controller.eject() }
            )
            MainTabView(
                controller: controller,
                libraryStore: libraryStore,
                playlistStore: playlistStore
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StorageBarView(
                breakdown: controller.storage,
                pending: libraryStore.pending,
                canSync: canSync,
                onSync: startSync
            )
        }
        .frame(minWidth: 880, minHeight: 600)
        // "New" means "not on the iPod", so the library store needs the
        // device's track list. Feed it here rather than handing the store a
        // reference to the controller — this stays a one-way push, and
        // `initial: true` covers an iPod that was already mounted at launch.
        .onChange(of: controller.snapshot, initial: true) { _, snapshot in
            libraryStore.applyDeviceSnapshot(snapshot)
            playlistStore.applyDeviceSnapshot(snapshot)
        }
        // Checking a playlist selects its tracks. Same one-way push as the
        // device snapshot above: the playlist store resolves its entries to
        // paths, the library store canonicalizes them against the scan.
        //
        // Three triggers, because three different things invalidate the set:
        // the user checking a playlist, a reload picking up edited .m3u files,
        // and a new library root changing what relative entries resolve to.
        .onChange(of: playlistStore.selectedNameKeys, initial: true) { _, _ in
            pushPlaylistSelection()
        }
        .onChange(of: playlistStore.playlists.map(\.id)) { _, _ in
            pushPlaylistSelection()
        }
        .onChange(of: libraryStore.libraryRoot) { _, _ in
            pushPlaylistSelection()
        }
        .task {
            DockProgressTracker.shared.start(engine: syncEngine, store: libraryStore)
        }
        .sheet(isPresented: $showSyncSheet) {
            SyncSheetView(engine: syncEngine, onCommit: commitSync)
        }
    }

    private func pushPlaylistSelection() {
        libraryStore.applyPlaylistSelection(
            playlistStore.selectedTrackPaths(libraryRoot: libraryStore.libraryRoot)
        )
    }

    /// Playlists bound for the iPod. In `.entireLibrary` mode the per-playlist
    /// checkboxes are inert and everything goes, matching iTunes — where the
    /// same radio governed playlists and tracks together.
    private var playlistsToSync: [Playlist] {
        libraryStore.syncMode == .entireLibrary
            ? playlistStore.playlists
            : playlistStore.selectedPlaylists
    }

    private var canSync: Bool {
        controller.status == .ready && libraryStore.libraryRoot != nil
    }

    private func startSync() {
        guard canSync,
              let root = libraryStore.libraryRoot,
              let device = controller.device else {
            Log.ui.warning("sync clicked but cannot sync (status=\(controller.status), root=\(libraryStore.libraryRoot != nil))")
            return
        }
        Log.ui.info("user clicked Sync")
        showSyncSheet = true
        Task {
            await syncEngine.plan(
                libraryRoot: root,
                library: libraryStore.library,
                selectedPaths: libraryStore.effectiveSelectedPaths,
                playlists: playlistsToSync,
                device: device,
                freeBytes: controller.storage.free
            )
        }
    }

    private func commitSync() {
        guard case let .planned(plan) = syncEngine.state,
              let root = libraryStore.libraryRoot,
              let device = controller.device else { return }
        Log.ui.info("user confirmed Sync")
        Task {
            await syncEngine.execute(
                plan: plan,
                libraryRoot: root,
                playlists: playlistsToSync,
                device: device
            )
            // Refresh device info + storage so the bottom bar reflects the new totals.
            controller.refresh()
        }
    }
}

#Preview {
    ContentView()
}

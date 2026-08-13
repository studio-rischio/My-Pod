import SwiftUI

struct MusicTabView: View {
    @Bindable var store: MusicLibraryStore

    var body: some View {
        VStack(spacing: 0) {
            // With the folder picker moved to General, everything left in the
            // toolbar is about a library that's been scanned — so before one is
            // chosen it would render as an empty strip above the empty state.
            if store.libraryRoot != nil {
                toolbar
                Divider()
            }
            content
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        // No library-folder control here on purpose — it lives in General ▸
        // Library, so there's one place to change it. The empty state below
        // keeps its own picker, since a first run would otherwise dead-end on
        // a screen with no way forward.
        HStack(spacing: 12) {
            Spacer()

            if store.newTrackCount > 0 {
                Label("\(store.newTrackCount) new", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .imageScale(.small)
                    .monospacedDigit()
                    .help("Tracks in your library that aren't on the iPod yet")
            }

            switch store.scanState {
            case .scanning:
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            case .ready(let date):
                Text("Scanned \(date.formatted(.relative(presentation: .numeric)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    store.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
            case .empty:
                Text("No tracks found").font(.caption).foregroundStyle(.secondary)
                Button("Rescan") { store.rescan() }
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if store.libraryRoot == nil {
            chooseRootEmptyState
        } else {
            HSplitView {
                LibraryTreeView(store: store)
                    .frame(minWidth: 360)
                detailPanel
                    .frame(minWidth: 240)
            }
        }
    }

    private var chooseRootEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No music library selected")
                .font(.title3)
            Text("Pick a Plex-structured folder: Library/Artist/Album/Track")
                .foregroundStyle(.secondary)
            Button("Choose Library Folder…") { pickRoot() }
                .controlSize(.large)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Selection")
                .font(.headline)

            HStack {
                Text("Tracks:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.selectionTrackCount) of \(store.library.totalTracks)")
                    .monospacedDigit()
            }
            HStack {
                Text("Size:")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(byteCount(store.selectionSize))
                    .monospacedDigit()
            }

            HStack {
                Button("Select All") { store.selectAll() }
                    .disabled(store.library.totalTracks == 0 || store.selectionIsLocked)
                Button("Clear") { store.clearSelection() }
                    .disabled(store.selectedTrackPaths.isEmpty || store.selectionIsLocked)
            }

            if store.selectionIsLocked {
                Text("Syncing your entire music library. Change this in General to pick what syncs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            newMusicSection

            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var newMusicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Music")
                .font(.headline)

            Toggle("Select new music automatically", isOn: $store.autoSelectNewMusic)
                .help("Check new albums as they appear — newest first, for as long as the iPod has room.")
                .disabled(store.selectionIsLocked)

            if store.deviceSnapshot == nil {
                Text("Connect your iPod to see what's new.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.newTrackCount == 0 {
                Text("Everything in your library is on the iPod.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Not on iPod:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.newTrackCount) tracks in \(store.newAlbumIDs.count) albums")
                        .monospacedDigit()
                        .font(.callout)
                }
            }
        }
    }

    private func pickRoot() {
        if let url = FolderPicker.chooseLibraryRoot() {
            store.chooseRoot(url)
        }
    }
}

private func byteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
}

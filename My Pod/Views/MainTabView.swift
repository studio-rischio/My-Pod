import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case general = "General"
    case music = "Music"
    case playlists = "Playlists"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "info.circle"
        case .music: "music.note"
        case .playlists: "music.note.list"
        }
    }
}

struct MainTabView: View {
    let controller: IPodController
    @Bindable var libraryStore: MusicLibraryStore
    @Bindable var playlistStore: PlaylistStore
    @State private var selection: MainTab = .general

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $selection)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            Group {
                switch selection {
                case .general:
                    GeneralTabView(controller: controller)
                case .music:
                    MusicTabView(store: libraryStore)
                case .playlists:
                    PlaylistsView(playlistStore: playlistStore, libraryStore: libraryStore)
                }
            }
        }
        .onChange(of: selection) { _, new in
            Log.ui.debug("tab changed: \(new.rawValue)")
        }
    }
}

/// Custom segmented bar that shows icon + title per segment. macOS's native
/// segmented `Picker` only renders title OR icon, not both, so we draw it
/// ourselves to match the requested design.
private struct TabBar: View {
    @Binding var selection: MainTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases) { tab in
                TabBarItem(
                    tab: tab,
                    selected: selection == tab,
                    onSelect: { selection = tab }
                )
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}

private struct TabBarItem: View {
    let tab: MainTab
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .font(.callout)
                Text(tab.rawValue)
                    .font(.callout)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.20) : Color.clear)
            )
            .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
    }
}

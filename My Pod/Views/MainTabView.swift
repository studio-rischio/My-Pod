import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case general = "General"
    case music = "Music"
    case playlists = "Playlists"
    case manual = "Manual"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "info.circle"
        case .music: "music.note"
        case .playlists: "music.note.list"
        case .manual: "hand.draw"
        }
    }

    /// Which tabs exist for an iPod in this mode.
    ///
    /// Mirroring the library and managing by hand are mutually exclusive, so
    /// only one set is ever reachable. That's what stops the two models being
    /// used against each other: a manually managed iPod has no Music tab to
    /// tick and no Sync button to press, so nothing can quietly remove what was
    /// added by hand. Sync becomes unreachable rather than conditionally
    /// modified, which is one fewer branch to keep correct forever.
    static func visible(manageManually: Bool) -> [MainTab] {
        manageManually ? [.general, .manual] : [.general, .music, .playlists]
    }
}

struct MainTabView: View {
    let controller: IPodController
    @Bindable var libraryStore: MusicLibraryStore
    @Bindable var playlistStore: PlaylistStore
    @Bindable var manualStore: ManualTransferStore
    @State private var selection: MainTab = .general

    private var profileStore: DeviceProfileStore { .shared }

    private var tabs: [MainTab] {
        MainTab.visible(manageManually: profileStore.active.manageManually)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabBar(tabs: tabs, selection: $selection)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            Group {
                switch selection {
                case .general:
                    GeneralTabView(
                        controller: controller,
                        libraryStore: libraryStore,
                        playlistStore: playlistStore
                    )
                case .music:
                    MusicTabView(store: libraryStore)
                case .playlists:
                    PlaylistsView(playlistStore: playlistStore, libraryStore: libraryStore)
                case .manual:
                    ManualTabView(controller: controller, store: manualStore)
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .layoutPriority(1)
        }
        .onChange(of: selection) { _, new in
            Log.ui.debug("tab changed: \(new.rawValue)")
        }
        // Swapping iPods can pull the current tab out from under the user — a
        // manually managed device has no Music tab. Fall back rather than
        // rendering a tab that is no longer in the bar.
        .onChange(of: tabs, initial: true) { _, available in
            guard !available.contains(selection) else { return }
            selection = available.first ?? .general
        }
    }
}

/// Custom segmented bar that shows icon + title per segment. macOS's native
/// segmented `Picker` only renders title OR icon, not both, so we draw it
/// ourselves to match the requested design.
private struct TabBar: View {
    let tabs: [MainTab]
    @Binding var selection: MainTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
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

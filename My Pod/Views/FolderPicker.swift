import AppKit

/// The two folder pickers the app needs, in one place.
///
/// Both are reachable from more than one screen — the library root from
/// General ▸ Library and from the Music tab's first-run empty state — and an
/// `NSOpenPanel` configured slightly differently in each would give the same
/// action two different prompts.
enum FolderPicker {
    static func chooseLibraryRoot() -> URL? {
        choose(
            message: "Pick your Plex-structured music library root.",
            what: "library folder"
        )
    }

    static func choosePlaylistFolder() -> URL? {
        choose(
            message: "Pick the folder holding your .m3u playlists.",
            what: "playlist folder"
        )
    }

    private static func choose(message: String, what: String) -> URL? {
        Log.ui.info("user opened \(what) picker")
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else {
            Log.ui.info("\(what) picker cancelled")
            return nil
        }
        return url
    }
}

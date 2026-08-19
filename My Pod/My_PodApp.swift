//
//  My_PodApp.swift
//  My Pod
//
//  Copyright (c) 2026 Studio Rischio LLC
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI

@main
struct My_PodApp: App {
    @Environment(\.openWindow) private var openWindow

    // The app's long-lived state lives here rather than in `ContentView`.
    //
    // `@State private var x = Thing()` runs `Thing()` on every init of the
    // enclosing struct and throws away all but the first. A View struct is
    // re-inited on every redraw; an App struct is built once. Holding these in
    // the view meant an `IPodController`, a `PlaylistStore` reload and a whole
    // library scan were constructed and discarded per redraw.
    @State private var controller = IPodController()
    @State private var libraryStore = MusicLibraryStore()
    @State private var playlistStore = PlaylistStore()
    @State private var manualStore = ManualTransferStore()
    @State private var syncEngine = SyncEngine()

    init() {
        Log.ui.info("app launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                controller: controller,
                libraryStore: libraryStore,
                playlistStore: playlistStore,
                manualStore: manualStore,
                syncEngine: syncEngine
            )
        }
        .commands {
            // Replace the system "About" menu item with one that opens our
            // custom AboutView window.
            CommandGroup(replacing: .appInfo) {
                Button("About \(appName)") {
                    openWindow(id: "about")
                }
                // The app menu, not Help. That's where macOS puts Check for
                // Updates — directly under About — and it's where people look
                // for it, whatever the Help menu might suggest.
                Button("Check for Updates…") {
                    UpdateChecker.shared.presentAndCheck()
                }
            }

            // The stock Help item opens a help book this app doesn't ship, so
            // it just errors. Replace it with what someone opening Help
            // actually wants. Unlike the button in the log window, this reports
            // the *whole* log — there's no visible filter here to inherit.
            CommandGroup(replacing: .help) {
                Button("Report a Bug…") {
                    BugReporter.openIssue(log: LogStore.exportText(LogStore.shared.entries))
                }
                Button("View the Debug Log") {
                    openWindow(id: "debug-log")
                }
                Divider()
                Button("\(appName) Website") {
                    if let url = URL(string: "https://rischio.studio/My-Pod/") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // Settings scene. SwiftUI puts this behind Cmd-, and adds the
        // Settings… item to the app menu on its own.
        Settings {
            SettingsView()
        }

        // About window — opened by the About menu item above.
        Window("About \(appName)", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        // Window scene auto-creates a "Debug Log" entry in the Window menu.
        Window("Debug Log", id: "debug-log") {
            LogsView()
                .frame(minWidth: 700, minHeight: 400)
        }
    }

    /// Display name for the app, used in menu titles. Pulled from the bundle
    /// so a name change in build settings propagates without code edits.
    private var appName: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "My Pod"
    }
}

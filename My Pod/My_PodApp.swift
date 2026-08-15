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

    init() {
        Log.ui.info("app launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Replace the system "About" menu item with one that opens our
            // custom AboutView window.
            CommandGroup(replacing: .appInfo) {
                Button("About \(appName)") {
                    openWindow(id: "about")
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

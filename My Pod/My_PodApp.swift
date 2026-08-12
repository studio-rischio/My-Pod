//
//  My_PodApp.swift
//  My Pod
//
//  Copyright (c) 2026 Studio Rischio LLC
//  SPDX-License-Identifier: MIT
//

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

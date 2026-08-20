// AboutView.swift
//
// Custom About window content. Replaces the system about panel via
// `CommandGroup(replacing: .appInfo)` in My_PodApp so we can show
// the app icon, version/build numbers, an attribution line for the
// bundled open-source tech, and the publisher/licence block. Reads app
// identity from `Bundle.main.infoDictionary` so a build-settings version
// or copyright bump propagates automatically.

import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            appIcon
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)

            Text(appName)
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version \(shortVersion) (\(buildVersion))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text("A native macOS sync app for classic iPods. Mirrors a Plex-structured music library, transcodes non-iPod-playable formats with afconvert, and writes the iTunesDB via a modified libgpod.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            Rectangle().fill(Color(NSColor.separatorColor)).frame(width: 220, height: 0.5)

            // Bundled-tech credit. libgpod (modified fork) is vendored under
            // core/libgpod and statically linked into the app.
            VStack(spacing: 3) {
                creditLine(
                    "libgpod",
                    url: "https://gitlab.gnome.org/Archive/libgpod",
                    note: "iTunesDB read/write"
                )
            }

            // Publisher block. The copyright string itself comes from
            // NSHumanReadableCopyright so the build setting stays the single
            // source of truth; the studio link and licence summary are this
            // project's own identity, so they ride behind the same guard — a
            // fork that clears the setting gets none of the three, rather than
            // inheriting Studio Rischio's attribution.
            if !copyright.isEmpty {
                Rectangle().fill(Color(NSColor.separatorColor)).frame(width: 220, height: 0.5)

                VStack(spacing: 4) {
                    Text(copyright)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let studio = URL(string: "https://rischio.studio") {
                        Link("rischio.studio", destination: studio)
                            .font(.caption2)
                    }

                    // Licence split stated in the app itself, not just the
                    // repo: libgpod is statically linked, so the LGPL notice
                    // travels with the binary.
                    Text("App code MIT-licensed · bundled libgpod LGPL 2.1 or later")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Bundled-dependency credit row: name (left) and a hint (right) on
    // one line, link styling so the whole row is clickable.
    @ViewBuilder
    private func creditLine(_ name: String, url: String, note: String) -> some View {
        HStack(spacing: 6) {
            if let u = URL(string: url) {
                Link(name, destination: u)
                    .font(.system(size: 11, weight: .medium))
            } else {
                Text(name).font(.system(size: 11, weight: .medium))
            }
            Text("·")
                .foregroundStyle(.tertiary)
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // Running app's icon, looked up via NSApplication. Uses the icon the
    // OS actually shows for the bundle, so swapping the app icon
    // automatically updates this view.
    private var appIcon: Image {
        if let ns = NSApplication.shared.applicationIconImage {
            return Image(nsImage: ns)
        }
        return Image(systemName: "ipod")
    }

    // App display name from CFBundleDisplayName (INFOPLIST_KEY_CFBundleDisplayName)
    // with CFBundleName as a fallback.
    private var appName: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "My Pod"
    }

    // Marketing version, e.g. 1.0. Set via MARKETING_VERSION build
    // setting, landed as CFBundleShortVersionString.
    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // Build number, e.g. 1. Set via CURRENT_PROJECT_VERSION, landed as
    // CFBundleVersion.
    private var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    // Copyright line from NSHumanReadableCopyright so a single
    // build-settings string is the source of truth. Empty rather than a
    // hardcoded fallback — a fork that clears the build setting should get
    // no copyright line, not this project's.
    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }
}

#Preview {
    AboutView()
}

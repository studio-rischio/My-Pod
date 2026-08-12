# My Pod

A native macOS app for syncing music to classic iPods, built on [libgpod](https://gitlab.gnome.org/Archive/libgpod).

Apple removed iPod support from macOS years ago. My Pod puts a modern SwiftUI interface on top of libgpod so a click-wheel iPod can still be kept in sync with a music library on disk — including transcoding formats the iPod can't play, writing cover art, and syncing playlists.

![The General tab, showing device details and the storage bar](docs/screenshots/01-general-tab.webp)

## Features

- **Automatic device detection** — the iPod is picked up as soon as it mounts; no pairing or setup.
- **Library mirroring** — pick a Plex-structured folder (`Root/Artist/Album/Track`) and check the artists, albums or tracks you want. Sync is a two-way mirror: checked music is added, unchecked music is removed.
- **New-music highlighting** — anything in your library that isn't on the iPod is marked with a dot, rolled up onto album and artist rows, and counted in the toolbar. Optionally it's checked for you automatically, newest albums first, for as long as the device has room.
- **Transcoding** — FLAC, OGG, Opus, WMA and APE are converted to AAC 256 kbps `.m4a` via `afconvert`, cached in a hidden `.mypod/` folder beside the source so a given file is only ever encoded once.
- **Cover art** — artwork is located per album and written into the iPod's database as rendered thumbnails.
- **Playlists** — backed by plain `.m3u` files in `~/Music/MyPodPlaylists/`, with a drag-and-drop editor.
- **Dock progress** — sync progress is drawn onto the app icon, so you can start a sync and switch away.

### Browsing and selecting music

The Music tab is the library. Checkboxes drive what syncs; the dot marks what isn't on the iPod yet.

![The Music tab, showing the library tree with new-music dots and the sync selection panel](docs/screenshots/02-music-library.webp)

### Reviewing a sync before it runs

Nothing is written until you confirm. The plan shows exactly what will be added, removed, left alone, and transcoded.

![The sync plan sheet, listing tracks to add, remove, leave unchanged, and convert](docs/screenshots/03-sync-plan.webp)

### Running the sync

Sync runs in phases, each with its own progress and a working cancel. Cancelling finishes the current track and saves what's already been done, so the iPod is never left mid-write.

| Converting | Copying |
|---|---|
| ![Transcoding tracks to AAC, with progress and time remaining](docs/screenshots/04-sync-converting.webp) | ![Copying tracks onto the iPod, showing the current track](docs/screenshots/05-sync-copying.webp) |

| Saving | Complete |
|---|---|
| ![Writing the iTunesDB and rendering artwork thumbnails](docs/screenshots/06-sync-saving.webp) | ![Sync complete, summarising tracks added, removed, and skipped](docs/screenshots/07-sync-complete.webp) |

### Playlists

Backed by plain `.m3u` files in `~/Music/MyPodPlaylists/`, so anything can read them. Drag tracks across from the library to build one; they sync to the iPod as real playlists.

![The Playlists tab, showing a playlist and its tracks](docs/screenshots/08-playlists.webp)

## Download

Grab the latest `My-Pod-*-arm64.zip` from [Releases](https://github.com/studio-rischio/My-Pod/releases),
unzip it, and drag `My Pod.app` to `/Applications`. Everything it needs is inside the bundle — no
Homebrew required to run it.

Apple silicon only. On an Intel Mac, build from source (see below) with `BREW_PREFIX=/usr/local`.

The app is signed ad-hoc rather than with an Apple Developer ID, so macOS quarantines it on download
and reports it as damaged. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine "/Applications/My Pod.app"
```

Or open it the first time via System Settings → Privacy & Security → **Open Anyway**. Building from
source avoids this entirely.

## Requirements

These are for building from source; the release download needs none of them.

- macOS 15.7 or later
- Xcode 26 or later
- Homebrew

Install the C dependencies:

```bash
brew install glib pkg-config
```

The first build also generates libgpod's `configure` script, which needs the autotools. These aren't required for subsequent builds:

```bash
brew install autoconf automake libtool gtk-doc intltool
```

## Building

```bash
git clone https://github.com/studio-rischio/My-Pod.git
cd My-Pod
./build.sh
```

`build.sh` compiles the vendored libgpod into a static library (first run only — it takes a few minutes), builds the app, and launches it. Use `./build.sh build` to skip launching, or `./build.sh clean` to remove all build output.

You can also open `My Pod.xcodeproj` and build normally; a run-script phase builds libgpod if it's missing.

## Project layout

```
My Pod/          App source
  IPodKit/       C shim exposing libgpod to Swift (ipod-api.c/.h + bridging header)
  Models/        Value types — library, tracks, sync plan, device
  Services/      Scanning, conversion, sync engine, device control
  Views/         SwiftUI interface
Vendor/libgpod/  Vendored libgpod (modified fork), statically linked
Scripts/         build-libgpod.sh
Config/          MyPod.xcconfig — search paths, link flags, sandbox settings
docs/            Project page (GitHub Pages) and its screenshots
icon/            App icon design source
```

Swift talks to libgpod through `IPodKit/ipod-api.c`, a small C wrapper that keeps GLib's memory semantics (`GList`, `GHashTable`, `GError`) out of Swift. Everything above it is ordinary Swift.

## How it works

**Library layout.** Music is read from a Plex-style tree — `Root/Artist/Album/Track`. Track numbers and titles are parsed from filenames.

**Matching.** The iPod's database doesn't store source file paths, so library tracks are matched to device tracks on `(artist, album, title)`, Unicode-normalised so accented titles compare equal across the filesystem and the database.

**Transcoding.** Formats the iPod can't play are encoded with `afconvert` to AAC-LC 256 kbps, constrained VBR, forced to 44.1 kHz. Those specifics matter on older hardware: true VBR breaks seeking on an iPod Photo, and hi-res sources passed through at 48 or 96 kHz skip during playback. The conversion cache is versioned, so changing the encoder settings invalidates it automatically.

**Metadata.** `afconvert` output carries no tags, so title, artist, album and artwork are written directly into the iPod database rather than embedded in the file. The iPod displays everything correctly; previewing a cached `.m4a` in Finder or Music.app will show no tags.

## Acknowledgements

Built on [libgpod](https://gitlab.gnome.org/Archive/libgpod), which does the real work of reading and writing the iTunesDB format. The copy in `Vendor/libgpod` is a modified fork.

## License

The split follows the directory layout:

| Path | License |
|---|---|
| `My Pod/`, `Scripts/`, `Config/`, root build scripts | [MIT](LICENSE) |
| `Vendor/libgpod/` | LGPL 2.1 or later |

`My Pod/IPodKit/ipod-api.c` is MIT despite linking libgpod. It contains no libgpod code — it calls the public API and includes `itdb.h`, which LGPL 2.1 §5 defines as a *"work that uses the Library"* rather than a derivative work.

Because libgpod is linked **statically**, LGPL 2.1 §6 requires that anyone distributing a compiled binary also provide the source or object files needed to relink against a modified libgpod. Distributing this repository's source satisfies that; shipping a prebuilt `.app` or disk image on its own does not.

## Trademarks

iPod, iTunes and macOS are trademarks of Apple Inc. This project is not affiliated with, authorised by, or endorsed by Apple.

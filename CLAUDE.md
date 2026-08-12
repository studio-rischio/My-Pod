# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS SwiftUI app that syncs music to click-wheel iPods by statically linking a vendored,
modified fork of **libgpod** (LGPL 2.1+). App code is MIT. See [README.md](README.md) for the
user-facing description.

## Build

```bash
./build.sh              # build C deps if needed, build app, launch it
./build.sh build        # same, without launching
./build.sh clean        # clean app build output + libgpod artifacts

CONFIG=Release ./build.sh build      # Debug is the default
```

The first run compiles libgpod (a few minutes). Subsequent runs skip it — `Scripts/build-libgpod.sh`
short-circuits when `Vendor/libgpod/src/.libs/libgpod.a` exists. Force a libgpod rebuild with
`./Scripts/build-libgpod.sh --force`. Xcode builds work too; a "Build libgpod" run-script phase
covers the same ground.

Prerequisites: `brew install glib pkg-config`, plus `brew install autoconf automake libtool gtk-doc
intltool` only when `Vendor/libgpod/configure` still needs generating.

### Cutting a release

```bash
CONFIG=Release ./build.sh build
./Scripts/bundle-app.sh                    # make the .app self-contained
ditto -c -k --sequesterRsrc --keepParent \
  "build/Build/Products/Release/My Pod.app" "My-Pod-<version>-arm64.zip"
```

`bundle-app.sh` exists because **only libgpod is static** — the app still links glib, gobject,
gmodule, intl, libplist and gdk-pixbuf from Homebrew by absolute path, so an unbundled `.app` dies
with "Library not loaded" anywhere Homebrew isn't installed at that exact prefix. The script walks
the dependency graph (the transitive set is 10 dylibs, not 6), rewrites load commands to `@rpath`,
**deletes the Homebrew `LC_RPATH` entries** so a machine that does have Homebrew can't shadow the
bundled copies with an incompatible version, and re-signs — rewriting load commands invalidates the
signature. Use `ditto`, not `zip`; `zip` corrupts the signature.

`Config/MyPod.xcconfig` strips the Release build (`DEPLOYMENT_POSTPROCESSING` + `STRIP_INSTALLED_PRODUCT`
+ `STRIP_STYLE = debugging`, all `[config=Release]`) and turns off
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS`. Without the first three, the executable keeps the linker's
debug map — N_OSO stabs naming every `.o` by absolute path, embedding the builder's home directory
~58 times in a binary that otherwise holds nothing personal. `strings` won't show them; they're in
the symbol table. Without the fourth, Xcode injects `com.apple.security.get-task-allow`, which lets
any process attach a debugger to the shipped app. Verify before uploading — both should print 0:

```bash
APP="build/Build/Products/Release/My Pod.app"
nm -ap "$APP/Contents/MacOS/My Pod" | grep -c OSO
codesign -d --entitlements - "$APP" 2>/dev/null | grep -c get-task-allow
```

Ship **only** the `.app`. The `.dSYM` built beside it still carries the full `DW_AT_comp_dir` build
paths by design — that is what it's for — so it must never go into a release.

Bump `MARKETING_VERSION` in the project and the download button + version line in `docs/index.html`,
which hardcode the asset URL (`releases/download/v<version>/My-Pod-<version>-arm64.zip`). The page
is served by GitHub Pages from `main` → `/docs`, so pushing publishes it.

Everything the page loads must live **inside** `docs/` — Pages serving from `/docs` treats that
folder as the site root and cannot reach `../icon/`. Hence `docs/app-icon.png` and `docs/icon.svg`
are copies; `icon/` remains the design source (the `.afdesign` and its component SVGs).

Releases are arm64-only and ad-hoc signed (there is no `DEVELOPMENT_TEAM`), so users must clear the
quarantine flag. Notarizing would require a Developer ID and turning on hardened runtime, which is
currently off. Because libgpod is statically linked, **any binary release must be accompanied by the
corresponding source** — see the licensing section.

**There is no test target and no tests.** Verification is by building and running against a real
device. The highest-value check before publishing changes is a fresh-clone build from tracked files
only, which catches things `.gitignore` accidentally excludes:

```bash
DEST=$(mktemp -d)/MyPod && mkdir -p "$DEST"
git archive HEAD | tar -x -C "$DEST" && cd "$DEST" && ./build.sh build
```

## Architecture

Four layers, bottom-up:

1. **`Vendor/libgpod/`** — upstream C library that reads/writes the iTunesDB format. Statically
   linked.
2. **`My Pod/IPodKit/ipod-api.{c,h}`** — the only place GLib types appear. Exposes an opaque
   `IPodDB*` plus plain-C structs so nothing above it sees `GList`/`GHashTable`/`GError`. Reached
   from Swift through `My_Pod-Bridging-Header.h`.
3. **`My Pod/Models/IPodDevice.swift`** — a Swift `actor` wrapping `IPodDB*`, one method per C call,
   converting `IPodResult` into thrown `IPodError`s and freeing every returned C string.
4. **Services + Views** — ordinary Swift/SwiftUI. `IPodController` (@MainActor @Observable) owns the
   device lifecycle; `ContentView` wires the four stores together and passes state down.

Data flow for a sync: `VolumeWatcher` (mount notifications) → `IPodController.load` → `IPodDevice`
actor → `SyncEngine.plan` diffs the library against the device → `SyncSheetView` confirms →
`SyncEngine.execute` runs phases convert → remove → add → playlists → save.

### Concurrency model

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so **every type is main-actor-isolated
unless marked `nonisolated`**. That is why value types touched by background work (`TrackKey`,
`TrackInfo`, `LibraryTrack`/`MusicLibrary`, `AudioFormat`, `ConversionService`, `LibraryScanner`,
`Log`) carry an explicit `nonisolated`. Adding a type that the scanner, conversion service, or the
`IPodDevice` actor constructs means marking it `nonisolated` too.

### Track identity (`TrackKey`)

The iPod database stores no source file paths, so library↔device matching is on
`(artist, album, title)`, each NFC-normalized, trimmed, and lowercased. The same key drives the sync
diff, the Music tab's "new music" dots, and playlist entry resolution — they must agree or the three
features contradict each other.

macOS hands back filesystem strings in NFD; the iPod can't render combining marks. Strings are
therefore NFC-normalized at the C boundary in `IPodDevice.addTrack`/`createPlaylist` (file paths are
deliberately *not* normalized — the filesystem wants NFD).

Playlists have the same problem and the same answer: `Playlist.nameKey` (NFC, trimmed, lowercased)
is the identity used by the sync selection set, the plan's playlist diff, and the Playlists tab's
"not on the iPod yet" dots. `Playlist.id` is a fresh UUID on every `reload()`, so it can't be it.

## Constraints that break real hardware if changed casually

- **afconvert flags** (`ConversionService.export`): `-s 2` (constrained VBR, not `-s 3`), forced
  `aac@44100`. True VBR breaks seeking on an iPod Photo; passing hi-res sources through at 48/96 kHz
  causes playback skipping. Any change to encoder settings must bump
  `ConversionService.cacheVersion`, which invalidates every cached `.m4a` in the hidden `.mypod/`
  folders.
- **Conversion is decided by contents, not extension** (`AudioFormat.needsConversion(_:probe:)` +
  `AudioProbe`). `.m4a` covers both 256 kbps AAC and 24-bit/96 kHz ALAC, so `LibraryScanner` opens
  natively wrapped files and re-encodes them when they exceed `AudioFormat.maxSampleRate` (44100),
  are lossless above 16-bit, or carry an HE-AAC layer. Two traps: **HE-AAC only shows up in
  `kAudioFilePropertyFormatList`** — the data format reports a plain half-rate `aac` core, so
  checking `formatID` alone silently misses it, and the effective sample rate is the max across
  layers rather than the core's; and `mBitsPerChannel` is 0 for ALAC, whose depth lives in
  `mFormatFlags`. `mp3` is deliberately excluded from probing (the format can't exceed what the
  hardware handles, and probing it would dominate scan cost). A nil probe means "leave it alone", so
  unreadable or DRM'd files keep their old behaviour. Widening these rules does **not** need a
  `cacheVersion` bump — encoder settings are unchanged, so existing cached `.m4a` files stay valid.
- **Transcoded files carry no tags.** afconvert output has no metadata; title/artist/album/artwork
  are written into the iPod database instead. That is intentional — do not "fix" it by embedding
  tags, and expect cached `.m4a` files to look blank in Finder/Music.app.
- **Artwork ordering** in `ipod_add_track_full`: `itdb_track_set_thumbnails` must run *before*
  `itdb_track_add`, matching the known-working CLI flow. libgpod renders the thumbnail bytes lazily
  during `itdb_write`, so the source image file must still exist at save time (hence the sync
  artwork scratch dir living in Caches for the duration of a run).
- **`track->tracklen` must be non-zero** or the iPod silently skips the track — that's why
  `AudioMetadataReader` runs per track during the add phase.
- **Cancel semantics**: cancelling finishes the in-flight track, then saves. Never leave a path that
  aborts without `device.save()`; a half-written iTunesDB bricks the library.

## Build-system quirks worth knowing

`Config/MyPod.xcconfig` holds the search paths, link flags, and:
- `BREW_PREFIX` defaults to `/opt/homebrew` (Apple Silicon). Override there for other layouts.
- App sandbox and hardened runtime are **off** — the app needs unrestricted access to
  `/Volumes/<iPod>` and user-chosen library folders.
- `ENABLE_USER_SCRIPT_SANDBOXING = NO`, because the libgpod autotools build touches files that can't
  be enumerated as phase inputs/outputs.

`Scripts/build-libgpod.sh` deliberately uses `autoreconf -fi` rather than libgpod's own
`autogen.sh` (which probes for versioned automake binaries Homebrew doesn't install), and passes
`--disable-more-warnings` (vendoring the git tree trips configure's "you are a libgpod developer"
heuristic, which adds `-Werror` flags a 2007 codebase can't satisfy under modern clang).

## Licensing boundary

`My Pod/IPodKit/ipod-api.c` is MIT and must stay that way: it calls libgpod's public API and includes
`itdb.h`, but contains **no libgpod code**. Don't copy implementation out of `Vendor/libgpod/` into
it.

Avoid sweeping edits inside `Vendor/libgpod/` — it's an upstream fork and diffs against upstream
matter. It also gets no README or CLAUDE.md of its own.

## Conventions

- Logging goes through `Log.<category>` (`ui`, `device`, `library`, `playlist`, `convert`, `sync`,
  `ipod`, `artwork`). Each line mirrors to `os_log`, stderr, and the in-app Debug Log window. A new
  category must be added in three places: `Log`, `Logger.osLogs`, and `LogsView.categories`.
- Persistence is UserDefaults for library root / selection / auto-select state, and plain `.m3u`
  files in `~/Music/MyPodPlaylists/` for playlists. Track selection is stored as file **paths**, not
  URLs, to dodge URL canonicalization mismatches; playlist selection is stored as `Playlist.nameKey`s.
- Both tabs follow the same selection model: a checkbox per row, an "offered once" set so
  auto-select can't re-check something the user deliberately unchecked, and unchecked means *absent
  from the iPod* — an unchecked playlist that's on the device gets removed by the next sync, exactly
  as an unchecked track does.
- Library layout is Plex-style `Root/Artist/Album/Track`; track number and title are parsed from the
  filename by `LibraryScanner.parseFilename`, which mirrors the C-side `parse_track_filename`.

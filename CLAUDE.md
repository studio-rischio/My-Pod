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

Releases ship **two** zips, one per architecture — not a universal binary. Build both:

```bash
# Apple silicon
CONFIG=Release ./build.sh build
./Scripts/bundle-app.sh "build/Build/Products/Release/My Pod.app"
ditto -c -k --sequesterRsrc --keepParent \
  "build/Build/Products/Release/My Pod.app" "My-Pod-<version>-arm64.zip"

# Intel
ARCH=x86_64 CONFIG=Release ./build.sh build
./Scripts/bundle-app.sh "build-x86_64/Build/Products/Release/My Pod.app"
ditto -c -k --sequesterRsrc --keepParent \
  "build-x86_64/Build/Products/Release/My Pod.app" "My-Pod-<version>-x86_64.zip"
```

The two builds use separate derived-data trees (`build/` and `build-x86_64/`) so both can exist at
once; `bundle-app.sh` therefore needs its path argument rather than the default.

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

Bump `MARKETING_VERSION` in the project and **both** download buttons + the version line in
`docs/index.html`, which hardcode the asset URLs
(`releases/download/v<version>/My-Pod-<version>-{arm64,x86_64}.zip`). The page is served by GitHub
Pages from `main` → `/docs`, so pushing publishes it — which means pushing a version bump *before*
the release exists points both buttons at a 404. Cut the release first, then push the page.

**The page asks which Mac the user has; it must not try to detect it.** Safari and Chrome both
report `Intel Mac OS X 10_15_7` in `navigator.userAgent` on Apple silicon, so sniffing hands
M-series users the Intel build with full confidence. `navigator.userAgentData` exposes the real
architecture but exists only in Chromium. There is no signal that works in Safari, which is most of
this audience.

Everything the page loads must live **inside** `docs/` — Pages serving from `/docs` treats that
folder as the site root and cannot reach `../icon/`. Hence `docs/app-icon.png` and `docs/icon.svg`
are copies; `icon/` remains the design source (the `.afdesign` and its component SVGs).

Releases are ad-hoc signed (there is no `DEVELOPMENT_TEAM`), so users must clear the
quarantine flag. Notarizing would require a Developer ID and turning on hardened runtime, which is
currently off. Because libgpod is statically linked, **any binary release must be accompanied by the
corresponding source** — see the licensing section.

### Cross-compiling for Intel

`ARCH=x86_64 ./build.sh build`. The interesting problem isn't the Swift — Xcode cross-compiles that
happily — it's that Homebrew on Apple Silicon installs **arm64-only dylibs**, so an Intel build has
nothing to link against.

The obvious fix, a second Homebrew under `/usr/local` via Rosetta, means compiling glib and its
dependencies **from source**, because Homebrew no longer produces Intel bottles for current macOS.
But it still *hosts* the last ones it built, tagged `sonoma` — Homebrew's Intel tags carry no arch
prefix, so `sonoma` is x86_64 and `arm64_sonoma` is Apple silicon. `Scripts/fetch-intel-deps.sh`
downloads those into `Vendor/intel-deps/` and makes them usable:

- Bottles are **relocatable**: paths inside are the literal strings `@@HOMEBREW_PREFIX@@` and
  `@@HOMEBREW_CELLAR@@`, which Homebrew rewrites at install time. Nothing is installed here, so the
  script does that rewriting — in `.pc` files as text, in dylibs as load commands.
- Not every path is a placeholder. Intel bottles are built for `/usr/local` and a few `.pc` files
  bake that in literally. `gdk-pixbuf-2.0.pc` is one, and the failure is silent and nasty: an
  unrewritten `-I/usr/local/include/gdk-pixbuf-2.0` makes libgpod's configure report
  *"gdkpixbuf support is disabled"*, which builds and runs perfectly and **writes no artwork**.
  The script therefore verifies `gdk-pixbuf-2.0` resolves *and* that the header is reachable, and
  `build-libgpod.sh` greps `config.h` for `HAVE_GDKPIXBUF` and fails the build without it.
- `libtiff`, `webp`, `xz`, `zstd` and `lz4` are staged but **not linked by anything**. They're there
  because `gdk-pixbuf-2.0.pc` names `libtiff-4` in `Requires`, and pkg-config resolves `Requires`
  transitively before it will answer at all.
- `sqlite3`, `libxml-2.0` and `zlib` are macOS system libraries with no bottle. The script generates
  pkg-config shims pointing at the SDK, whose `.tbd` stubs carry every slice, so they're arch-neutral.
- The staged tree gets `opt/<formula>` symlinks so it's **shaped like a Homebrew prefix**. That's why
  the only build-settings change is pointing `BREW_PREFIX` at it.

`build-libgpod.sh` takes `ARCHS` and produces a **fat** `libgpod.a`, so the xcconfig names one path
for both architectures. libgpod's configure refuses to run VPATH while the source tree is already
configured, and `distclean` wipes `src/.libs`, so the arches can't be built side by side — each is
built in turn and its archive cached in `Vendor/libgpod-arch/`. That cache is what stops adding
x86_64 from re-doing arm64.

Both `Vendor/intel-deps/` and `Vendor/libgpod-arch/` are gitignored build products.

**There is no test target and no tests.** Verification is by building and running against a real
device. An Intel build can at least be smoke-tested on Apple silicon — it launches under Rosetta,
which exercises the same dyld path that "Library not loaded" failures show up in:

```bash
"build-x86_64/Build/Products/Release/My Pod.app/Contents/MacOS/My Pod"
```

That proves the bundle resolves. It does **not** prove syncing works on real Intel hardware. The highest-value check before publishing changes is a fresh-clone build from tracked files
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

## Design principle: guaranteed playback beats maximum quality

When a format decision is ambiguous, **convert**. The thresholds in `AudioFormat` are deliberately
tighter than what the hardware is documented to accept, and tighter than what a given iPod may in
practice play.

The failure modes are asymmetric. An unnecessary re-encode costs a little quality on a device whose
output stage is 16-bit regardless — nobody has ever filed a bug about it. A file passed through that
turns out to be unplayable costs a silent skip or a track that won't start, on hardware with no error
reporting, where the user cannot tell what went wrong or that the app is even involved.

Concretely: `maxSampleRate` stays at 44100 even though iPod classic is documented to 48 kHz, and
even though hardware testing on an iPod Photo found both 48 kHz AAC and 24-bit/48 kHz ALAC playing
cleanly. The original finding that motivated 44.1 kHz was *intermittent skipping across a full
album*, and a short clip playing correctly cannot disprove that. 24-bit lossless is likewise
re-encoded even where it plays, because the output pipeline is 16-bit either way.

**Do not relax the defaults to recover quality.** Anyone wanting the device's full capability has
Rockbox and other replacement firmware; this app's contract is that a sync always works. Relaxing a
default requires evidence of the *absence* of failure across full-length material on multiple
models — not the presence of success in a short test. Adding a threshold needs much less evidence
than removing one.

What *is* allowed is letting a user who knows their own hardware opt out per-install, which is what
`ConversionProfile` does (Settings ▸ Conversion). Three levels, default first, each a superset of
the last: 44.1 kHz/16-bit, then 48 kHz, then 48 kHz + 24-bit lossless. The looser two correspond to
bench tests F and B in `agent_space/ipod-test-files/results.txt`, which passed on an iPod Photo.
Two rules hold at every level, because they're not "probably fine" cases: **96 and 192 kHz are
always converted** (tests C and D refused to play outright), and **HE-AAC is never passed through**
(click-wheel decoders predate SBR, so the file plays audibly wrong rather than merely over-spec).
The default must stay `.maximumCompatibility` — a user who can't tell whether their model is
affected has to land on the safe behaviour without choosing it.

## Constraints that break real hardware if changed casually

- **afconvert flags** (`ConversionService.export`): `-s 2` (constrained VBR, not `-s 3`), and
  `aac@<rate>` where the rate comes from `ConversionProfile.encodeRate(sourceRate:)` — 44100 unless
  the user opted up. True VBR breaks seeking on an iPod Photo; passing hi-res sources through at
  48/96 kHz causes playback skipping. Any change to encoder settings must bump
  `ConversionService.cacheVersion`, which invalidates every cached `.m4a` in the hidden `.mypod/`
  folders.
- **Cached output is keyed by the rate it was encoded at**, not by the profile — `CacheLocation`
  appends `-48` to the directory (`v9-48/`) or filename (`Track-48.m4a`) for anything that isn't
  44.1 kHz, and appends nothing at 44.1. Both halves matter. No suffix at 44.1 means upgrading to a
  build that has this setting strands nothing. Keying on rate rather than profile means a 44.1 kHz
  source resolves to the same path under every profile — its output is byte-identical either way —
  so switching profiles to spare a handful of hi-res files doesn't re-transcode the whole library.
- **`encodeRate` never resamples upward and prefers halving to clamping**: 96 → 48 and 88.2 → 44.1
  are exact 2:1 decimations where 88.2 → 48 would not be. `agent_space/crackle-test` measured
  intersample overshoot nearly tripling through a rate conversion, so staying inside a rate family
  is worth the extra branch. An unknown source rate (0) falls back to 44.1, never upward.
- **Changing the profile requires a rescan, not just a refresh.** `needsConversion` is decided at
  scan time and baked into `LibraryTrack`, so `MusicLibraryStore` rescans on
  `ConversionProfile.didChange`. It also rebuilds `conversionForEstimates` — `ConversionService`
  captures the location and profile at init, so a long-lived instance answers "is this cached?"
  against wherever the cache used to be.
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

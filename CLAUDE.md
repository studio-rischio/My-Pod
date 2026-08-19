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
   device lifecycle; `ContentView` wires the stores together and passes state down.

Data flow for a sync: `VolumeWatcher` (mount notifications) → `IPodController.load` → `IPodDevice`
actor → `SyncEngine.plan` diffs the library against the device → `SyncSheetView` confirms →
`SyncEngine.execute` runs phases convert → remove → add → playlists → save.

**The long-lived stores are owned by `My_PodApp`, not `ContentView`, and must stay there.**
`@State private var x = Thing()` evaluates `Thing()` on *every* init of the enclosing struct and
discards all but the first. A View struct is re-inited on every redraw; an App struct is built once.
While these lived in `ContentView`, each redraw constructed and threw away an `IPodController`, a
`PlaylistStore` reload and a **full library scan** — measured at 126 scans in one launch of a
2,895-track library, pegging a core. Moving one back into a view reintroduces that silently: nothing
misbehaves, it's just permanently busy.

### Per-device profiles

Which iPod is attached decides the quality ceiling **and** the sync selection — an 8 GB nano can't
hold what a modded 256 GB classic does at any codec. `DeviceProfileStore.shared` (shared because
Settings is a separate scene that can't reach the main window's state) resolves the connected device
to a `DeviceProfile`; `ContentView` pushes that to `MusicLibraryStore.activate` and
`PlaylistStore.activate`. There is always exactly one active profile — the reserved *default* one
whenever nothing is connected, whose ceiling **is** `ConversionCeiling.current`.

Identity is a chain of namespaced tiers, matched on any identifier the device has ever presented:
`fw:` (libgpod's FirewireGuid, which survives My Pod's own reset but not a Disk Utility reformat),
then `vol:` (volume UUID), then `name:` (volume name + capacity). The weak `name:` tier only matches
profiles that have never carried a `fw:`, which deliberately gives a Disk-Utility-reformatted iPod a
fresh profile rather than risk merging two different devices into one — a wrong merge corrupts both
selections and isn't recoverable; a spurious new profile is.

Selections live under `MyPod.profile.<uuid>.*` keys rather than inside the profile record: they're
thousands of paths rewritten on every checkbox click, and holding them in the shared blob would
rewrite every device's state to save one. The UUID is internal and stable, so a device that changes
identity tier keeps its selection. `MusicLibraryStore.activate` must **not** intersect the incoming
selection against the scanned library — an iPod can connect before the first scan lands, and
intersecting against an empty library silently deletes and then persists an empty selection.

### Concurrency model

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so **every type is main-actor-isolated
unless marked `nonisolated`**. That is why value types touched by background work (`TrackKey`,
`TrackInfo`, `LibraryTrack`/`MusicLibrary`/`SourceFormat`, `AudioFormat`, `ConversionService`,
`LibraryScanner`, `DeviceProfile`, `Log`) carry an explicit `nonisolated`. Adding a type that the scanner, conversion service, or the
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

Concretely: `AudioFormat.baseSampleRate` stays at 44100 even though iPod classic is documented to
48 kHz, and even though hardware testing on an iPod Photo found both 48 kHz AAC and 24-bit/48 kHz
ALAC playing cleanly. The original finding that motivated 44.1 kHz was *intermittent skipping across a full
album*, and a short clip playing correctly cannot disprove that. 24-bit lossless is likewise
re-encoded even where it plays, because the output pipeline is 16-bit either way.

**Do not relax the defaults to recover quality.** Anyone wanting the device's full capability has
Rockbox and other replacement firmware; this app's contract is that a sync always works. Relaxing a
default requires evidence of the *absence* of failure across full-length material on multiple
models — not the presence of success in a short test. Adding a threshold needs much less evidence
than removing one.

What *is* allowed is letting a user who knows their own hardware opt out per-install, which is what
`ConversionCeiling` does (Settings ▸ Conversion). Four rungs, default first, ordered by quality:
`aac44`, `aac48`, `alac44`, `alac48`. They correspond to bench tests E/F/A/B in
`agent_space/ipod-test-files/results.txt`, all of which passed on an iPod Photo.

It is a **ceiling, not a target**. Material above it comes down to it; material below it is left
alone. That is why a 22 kHz AAC or a 128 kbps MP3 passes every rung untouched. "Above" means *out of
spec* — sample rate, bit depth, HE-AAC — and deliberately **not** bitrate: a 320 kbps MP3 is never
re-encoded under `aac44`, because lossy-to-lossy transcoding costs quality to save a little space.
MP3 is not probed at all, which would otherwise dominate scan cost.

Two rules hold at every rung, because they aren't "probably fine" cases: **96 and 192 kHz are always
converted** (tests C and D refused to play outright), and **HE-AAC is never passed through**
(click-wheel decoders predate SBR, so the file plays audibly wrong rather than merely over-spec).
The default must stay `.aac44` — a user who can't tell whether their model is affected has to land
on the safe behaviour without choosing it.

**Lossy sources never become lossless.** `targetCodec(sourceIsLossless:)` routes FLAC/APE/ALAC to
the ceiling's codec and everything else to AAC regardless. A 128 kbps OGG re-encoded as ALAC would
be roughly six times larger and recover nothing — the detail was discarded at the original encode.
Raising the ceiling raises a limit; it cannot put back what was never there.

## Constraints that break real hardware if changed casually

- **afconvert flags** (`ConversionService.export`): `-s 2` (constrained VBR, not `-s 3`), and
  `aac@<rate>` where the rate comes from `ConversionCeiling.encodeRate(sourceRate:)` — 44100 unless
  the user opted up. True VBR breaks seeking on an iPod Photo; passing hi-res sources through at
  48/96 kHz causes playback skipping. Any change to encoder settings must bump
  `ConversionService.cacheVersion`, which invalidates every cached `.m4a` in the hidden `.mypod/`
  folders.
- **`maxConcurrent` is *not* in that category** — it's a tuning constant, and it now scales with the
  machine (`max(2, min(8, activeProcessorCount / 2))`). It was a flat 2, defended by a claim that
  afconvert can't tolerate more than ~4 concurrent instances. That was wrong: the exclusivity it
  cited is an iOS hardware-codec concept and macOS AAC encoding is the software codec, and
  measurement found zero failures at 32. Scaling is near-linear to 8 and rolls off after, so the cap
  is politeness rather than safety. Numbers in `agent_space/bench-conversion.md`; changing it needs
  **no** `cacheVersion` bump, since the output bytes are identical.
- **ALAC output needs two afconvert passes and there is no way around it.** afconvert exposes no
  bit-depth flag for ALAC and defaults to *32-bit* source data, so a direct `-d alac@44100` yields a
  32-bit file — larger than a 24-bit original, and out of spec by this app's own rules. Even a
  16-bit FLAC comes back 32-bit. The pipeline is therefore `-d LEI16@<rate>` to a `.caf`, then
  `-d alac` from that. Verified: a 24-bit/96 kHz source lands at exactly the byte count of bench
  file A, the known-good 16-bit/44.1 kHz file. Anything this app encodes is 16-bit regardless of
  rung — the `alac48` rung's 24-bit allowance is a *passthrough* rule, and the output stage is
  16-bit anyway.
- **Cached output IS keyed by the ceiling, and collecting the unreferenced ones is load-bearing.**
  The quality setting is per-iPod, so two devices attached to the same library need two formats warm
  at once — hence `Converted/v9/<ceiling>/…` and `.mypod/<ceiling>/…`. That is *not* a return to 1.5,
  which keyed by sample rate and kept copies no one consumed. Here every cached ceiling is owned by a
  device profile, and `CacheInventory.collectUnused` deletes any that no profile references, at
  launch and after every profile change. Skip that and trying all four rungs leaves four encodings of
  the library on disk with nothing to say which are live. The consequence to know: switching a device
  A → B → A **re-encodes**, because A's cache is collected the moment nothing references it. That is
  the deliberate trade — bounded, predictable disk over a free undo.
- **`encodeRate` never resamples upward and prefers halving to clamping**: 96 → 48 and 88.2 → 44.1
  are exact 2:1 decimations where 88.2 → 48 would not be. `agent_space/crackle-test` measured
  intersample overshoot nearly tripling through a rate conversion, so staying inside a rate family
  is worth the extra branch. An unknown source rate (0) falls back to 44.1, never upward.
- **The scan records what a file *is*, never what should happen to it.** `LibraryTrack.format` is a
  `SourceFormat` — rate, depth, lossless, HE-AAC, duration — and `needsConversion(under:)` applies a
  ceiling to it at the point of use. That's what lets one scan serve several iPods at different
  quality settings, and why changing a ceiling is a recompute rather than a filesystem walk. It costs
  no extra I/O because the rungs form a ladder: anything in spec at the strictest rung (`.aac44`) is
  in spec at every rung, so the scanner probes exactly the files it always did. `ConversionService`
  still captures its ceiling and location at init, so `MusicLibraryStore` rebuilds
  `conversionForEstimates` whenever either changes — a long-lived instance would answer "is this
  cached?" against the wrong iPod.
- **Never give `ceiling:` a default argument.** `ConversionService.init` deliberately requires it.
  A default would compile, run, and silently answer for the wrong device — and under-reporting a
  lossless profile's sizes by ~3× is exactly what defeats `SyncPlan.fits` and fills the iPod partway
  through the add phase, after removals have run.
- **Size estimates must follow the ceiling.** `estimatedIPodBytes` branches on `targetCodec`, and
  the two differ by roughly 3×. The AAC path multiplies duration by `aacBitRate`; the ALAC path has
  no bitrate to multiply by, so it derives raw PCM from the *target* rate at 16-bit stereo and
  scales by `alacPCMRatio` (0.65, the pessimistic end of ALAC's real 0.50–0.70, erring toward
  headroom like `vbrOverheadFactor`). Getting this wrong is not cosmetic: `addedBytes` feeds
  `SyncPlan.shortfallBytes`, so an under-report makes `fits` return true and the device fills up
  partway through the add phase, *after* removals have run.
- **Conversion is decided by contents, not extension**
  (`AudioFormat.needsConversion(_:probe:ceiling:)` + `AudioProbe`). `.m4a` covers both 256 kbps AAC
  and 24-bit/96 kHz ALAC, so `LibraryScanner` opens natively wrapped files and re-encodes them when
  they exceed `ceiling.maxSampleRate`, are lossless deeper than `ceiling.maxBitDepth`, or carry an
  HE-AAC layer. The same probe also decides `isLossless`, which picks the target codec. Two traps: **HE-AAC only shows up in
  `kAudioFilePropertyFormatList`** — the data format reports a plain half-rate `aac` core, so
  checking `formatID` alone silently misses it, and the effective sample rate is the max across
  layers rather than the core's; and `mBitsPerChannel` is 0 for ALAC, whose depth lives in
  `mFormatFlags`. `mp3` is deliberately excluded from probing (the format can't exceed what the
  hardware handles, and probing it would dominate scan cost). A nil probe means "leave it alone", so
  unreadable or DRM'd files keep their old behaviour. Widening these rules does **not** need a
  `cacheVersion` bump — encoder settings are unchanged, so existing cached `.m4a` files stay valid.
- **`cover.jpg` is the only thing the app writes into the user's music library** besides the hidden
  `.mypod` conversion cache, and `CoverArt` is the only thing that writes it. It goes in squared —
  crop or fit, the user's choice, never left non-square — at up to 1000px, JPEG q0.85, with source
  metadata dropped so a phone photo's location tags don't ride along. 1000 is far above what the
  device needs (140×140 on iPod Photo, 100×100 on nano; libgpod renders its own thumbnails) and is
  for the user's library rather than the iPod. ImageIO throughout, never `NSImage`, which ignores
  EXIF orientation and rescales silently. Writing the file is enough to reach the device: it outranks
  every other name `ArtworkLocator` looks for, so no sync-path change was needed.
- **Transcoded files carry no tags.** afconvert output has no metadata; title/artist/album/artwork
  are written into the iPod database instead. That is intentional — do not "fix" it by embedding
  tags, and expect cached `.m4a` files to look blank in Finder/Music.app.
- **Artwork ordering** in `ipod_add_track_full`: `itdb_track_set_thumbnails` must run *before*
  `itdb_track_add`, matching the known-working CLI flow. libgpod renders the thumbnail bytes lazily
  during `itdb_write`, so the source image file must still exist at save time (hence the sync
  artwork scratch dir living in Caches for the duration of a run).
- **Artwork for tracks the iPod already has is a separate phase, and its baseline is load-bearing.**
  `SyncEngine.plan` treats an existing track as `unchanged` and never revisits it, and artwork is
  attached only during the add — so a cover acquired after an album synced would never reach the
  device. `ArtworkSync` closes that: each profile stores `artworkSyncedAt`, and an album whose cover
  file is newer than it (or that was queued by hand) gets `ipod_set_track_artwork` on every one of
  its tracks in the `artwork` phase. Saving through `AlbumArtSheet` queues explicitly as well as
  bumping the date, and that redundancy is deliberate: the baseline is stamped on first connect, so an
  iPod first seen *after* the save would have a baseline newer than the file and miss it forever.
  Two rules keep it from misfiring. An **unset** baseline means
  push *nothing*, not everything — `.distantPast` would re-push artwork for the whole library on the
  first sync after upgrading; `DeviceProfileStore.deviceChanged` sets it on every connect, which is
  both the migration and the seed for a new iPod. And the baseline moves **only after a save that
  landed**, so a cancelled or failed run leaves the same artwork pending rather than writing it off.
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
  Anything per-iPod (track selection, sync mode, playlist selection, offered-once) lives under
  `MyPod.profile.<uuid>.<name>` — see "Per-device profiles". `autoSelectNewPlaylists` stays global
  because it's a behaviour preference, not device state. Both migrations off the old app-wide keys
  are one-shot flags that *copy* rather than move, so downgrading to 1.6 still finds its own keys.
- Both tabs follow the same selection model: a checkbox per row, an "offered once" set so
  auto-select can't re-check something the user deliberately unchecked, and unchecked means *absent
  from the iPod* — an unchecked playlist that's on the device gets removed by the next sync, exactly
  as an unchecked track does.
- **Exactly two things reach the network, and both only on an explicit press.** `ArtworkSearch` runs
  on Search; `UpdateChecker` runs on My Pod ▸ Check for Updates… (`BugReporter` handing a URL to
  `NSWorkspace` aside). Neither runs at launch, on a timer, during a scan, or during a sync, and the
  promise stated in the app, the README and `docs/index.html` is *"nothing leaves your machine unless
  you ask"* — not "only one feature uses the network", which a third caller would quietly falsify.
  Adding an automatic update check is the specific thing that would break it: this audience keeps
  twenty-year-old hardware alive partly to avoid software that phones home, so it stays manual. That rule is stated in the sheet, the README and
  `docs/index.html`, so relaxing it silently would make all three untrue. Artist and album stay
  separate down the whole call because the two catalogues want opposite things — Apple's endpoint
  takes one free-text term, while MusicBrainz needs `artist:"…" AND release:"…"`; a free-text
  MusicBrainz query returns releases *titled* "Boards of Canada" by other artists where the fielded
  one returns the album at score 100. Cover Art Archive candidates are probed with a HEAD before
  being offered, because nothing in the MusicBrainz response says whether art exists and most
  releases have none — measured at two dead tiles per live one.
- Library layout is Plex-style `Root/Artist/Album/Track`; track number and title are parsed from the
  filename by `LibraryScanner.parseFilename`, which mirrors the C-side `parse_track_filename`.

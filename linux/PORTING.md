# Porting My Pod to Linux

Scope, plan and verification gates. Read `linux/CLAUDE.md` first if you are an agent picking this
up on a Linux host — the repository root `CLAUDE.md` describes the macOS build and will mislead you.

Written 2026-08-19 against `main` @ `6f2b58e`, the commit that moved the shared C to
`core/`. Companion to [win.md](win.md), which scopes the Windows one.

## Why this is worth doing before Windows

Everything that makes the Windows port hard is already solved on Linux, and the two ports
need the same separation between `core/` and the platform layer. Doing Linux first builds
that separation against a second real consumer while the hard Windows dependency problem
is still unsolved — and gives you a working second platform in the meantime.

## Part 1 — what is free

**`core/ipod-api.c` compiles unmodified.** Its entire system surface is:

```
stdio.h  stdlib.h  string.h  sys/types.h  sys/stat.h  dirent.h  ctype.h  time.h
glib.h   glib/gstdio.h
```

and its platform calls are `strdup` (58), `strcasecmp` (12), `unlink` (8), `stat` (7),
`opendir`/`readdir`/`closedir` (6 each), `S_ISDIR`/`S_ISREG`, `rmdir`. Every one is native
on Linux. **This is the file `win.md` defers as "later work" — on Linux there is no work.**

**`core/libgpod/` is a Linux library.** It is a fork of a GNOME project; autotools is its
native build, and glib, gdk-pixbuf, libplist, libxml2, sqlite3 and zlib are all packaged on
every distribution. No bottle-fetching, no cross-compile staging, none of
`Scripts/fetch-intel-deps.sh`.

**Licensing gets simpler, not harder.** The macOS build links libgpod *statically*, which is
why any binary release must ship the corresponding source. Linking it dynamically on Linux —
the normal thing there — drops that obligation to the ordinary LGPL one. We still publish our
fork's changes because we distribute a modified libgpod, but the static-link entanglement in
`LICENSE` stops applying to the app binary.

## Part 2 — what must be replaced

The C layer is 1 of the 4 architecture layers in `CLAUDE.md`. Layers 3 and 4 are Swift, and
`My Pod/Services/` alone is 6,314 lines. This is the actual cost of the port.

| What it does | macOS | Linux |
|---|---|---|
| Transcode | `afconvert` | `ffmpeg` |
| Probe format, read duration | AVFoundation | `libavformat` / `ffprobe` |
| Decode, square, write JPEG | ImageIO | **gdk-pixbuf** — already a dependency |
| Notice an iPod mounting | `NSWorkspace` mount notifications | udisks2 D-Bus signals, or inotify on `/proc/mounts` |
| Eject | `NSWorkspace.unmountAndEject` | udisks2 |
| Settings | `UserDefaults` | GSettings, or a plain config file |
| HTTP (artwork search, updates) | `URLSession` | libsoup or libcurl |
| Progress on the app icon | Dock tile | drop it; no portable equivalent worth the code |
| Interface | SwiftUI | see Part 4 |

Two of these are *already linked into the app today* through libgpod: glib and gdk-pixbuf.
That matters for the UI decision.

## Part 3 — the traps

### The conversion rules are a hardware contract, not a preference

`CLAUDE.md` is explicit that the thresholds in `AudioFormat` are deliberately tighter than the
hardware is documented to accept, because the failure modes are asymmetric — an unnecessary
re-encode costs a little quality, a file that turns out to be unplayable costs a silent skip on
hardware with no error reporting. **A Linux port must reproduce the rules, not re-derive them.**
`ConversionCeiling`, `SourceFormat.needsConversion` and `encodeRate` are pure logic and port as-is.

Two encoder details do *not* port as-is:

- **`-s 2` (constrained VBR) has no direct ffmpeg equivalent.** The macOS flag exists because
  true VBR breaks seeking on an iPod Photo — a real, observed failure. ffmpeg's native AAC
  encoder with `-b:a 256k` is ABR, which is closer to constrained VBR than to true VBR, but
  **this needs a bench test on real hardware before it ships.** Do not assume it inherits the
  macOS finding; the encoder is different.
- **The two-pass ALAC dance does not apply.** On macOS, ALAC needs `-d LEI16@rate` to a `.caf`
  and then `-d alac`, because afconvert exposes no bit-depth flag for ALAC and defaults to
  32-bit. That is an *afconvert workaround*, not an inherent requirement: ffmpeg takes
  `-c:a alac -sample_fmt s16p -ar 44100` in one pass. Same 16-bit output, half the work.

**HE-AAC detection is the one probe that needs real thought.** On macOS it only shows up in
`kAudioFilePropertyFormatList` — checking the data format alone silently misses it, and the
effective sample rate is the max across layers. The equivalent in libavformat is the codec
*profile* (`FF_PROFILE_AAC_HE` / `HE_V2`), which is a different mechanism reaching the same
answer. Get this wrong and the file plays audibly wrong rather than merely over-spec.

### Assumed away: one library, one app

`CacheLocation` can put converted audio in a hidden `.mypod/<ceiling>/` folder beside the music,
so a library shared between a Mac and a Linux box would have two different encoders writing the
same cache paths with byte-different output, and neither would notice.

**We are assuming a library is only ever managed by one installation of My Pod**, which makes this
a non-issue. Recorded because it is an assumption rather than a fact about the code: if that ever
stops being true, the cache path needs a platform token and this becomes a silent
wrong-file-on-the-iPod bug rather than a visible failure.

### `UpdateChecker` and release tags

Already flagged in `win.md`: `releases/latest` returns one release for the whole repository, so
a Linux or Windows release would announce itself to macOS users. Needs solving once, for all
platforms, before a second platform ships anything.

## Part 4 — the strategic question: rewrite, or port the Swift?

**Swift runs on Linux.** Foundation, Dispatch, the concurrency model and Observation are all
available; SwiftUI is not. That makes the choice much less binary than "rewrite it in C or Rust".

**Option A — port the Swift, replace only the platform edges.** `Models/` is value types with an
explicit `nonisolated` discipline already, and much of `Services/` is pure logic: `TrackKey`,
`SyncPlan`, `SyncEngine`, `ConversionCeiling`, `CacheInventory`, `DeviceProfile`. Those move with
modest changes. What genuinely needs rewriting is the AVFoundation, ImageIO, `afconvert` and
`NSWorkspace` touchpoints — plus all of `Views/`.

The prize is that the sync diff, the identity rules and the quality ladder stay **one
implementation**. Those are the parts where a divergence between platforms produces a corrupted
iPod rather than a cosmetic difference, and `CLAUDE.md` already warns that `TrackKey` must agree
across three features or they contradict each other. Two hand-maintained copies will drift.

The risk is the UI: SwiftUI is absent, and the Swift GTK bindings are immature enough that they
need evaluating before being relied on.

**Option B — rewrite the app layer in C or Vala with GTK4.** Native fit — glib and gdk-pixbuf are
already linked — and a large, stable ecosystem. The cost is maintaining a second implementation
of the rules above, forever, in a language with none of the actor isolation that currently keeps
the scanner, the conversion service and the device actor from stepping on each other.

**My recommendation is A, with the UI as a spike first.** Spend a day proving a Swift package on
Linux can (1) link `core/` and open a real iPod's database, and (2) draw a window. Item 1 is
near-certain and is the whole value of the `core/` extraction; item 2 is the actual risk. If the
UI spike fails, fall back to B having lost a day and gained a verified `core/` on Linux either way.

## Suggested order

1. **`core/` on Linux, no UI.** A CMake or autotools build that compiles `ipod-api.c` against a
   distro libgpod and runs a CLI that opens an iPod and lists tracks. Proves the extraction was
   worth doing and needs no decisions.
2. **The cache-collision fix**, in the macOS app, on `main`. It affects shipped behaviour and
   shouldn't wait for the port.
3. **The UI spike**, deciding Option A or B.
4. Everything else.

## Out of scope for now

Don't touch `core/libgpod/` — upstream fork, diffs against upstream matter. Don't add a UI
framework to the repo before step 3 decides which. Don't change the macOS build except for the
cache-path fix in step 2.

---

# Build, test and evaluation plan

Written to be executed on a Linux host by someone — or some agent — with **no prior context on
this project**. Each stage has a gate. Do not start a stage until the previous gate passes, and
report the gate output rather than a summary of it.

> This file is tracked on the `linux` branch so it travels with a clone. The working notes it grew
> out of live in `agent_space/`, which is gitignored and stays on the Mac.

## Stage 0 — host and toolchain

Record the distribution and versions before anything else; every later failure is read against them.

```bash
. /etc/os-release && echo "$PRETTY_NAME"
uname -m
gcc --version | head -1
pkg-config --version
ffmpeg -version | head -1
```

Build dependencies. `libgpod`'s `configure.ac` requires `glib-2.0 >= 2.16`, `gobject-2.0`,
`gmodule-2.0`, `sqlite3` and `libplist-2.0`; it optionally uses `libxml-2.0` (for
`SysInfoExtended`, which is where the FireWire GUID comes from — **not** optional for us, device
profiles depend on it) and `gdk-pixbuf-2.0` (artwork).

```bash
# Debian / Ubuntu
sudo apt install build-essential autoconf automake libtool pkg-config gtk-doc-tools intltool \
     libglib2.0-dev libplist-dev libsqlite3-dev libxml2-dev libgdk-pixbuf-2.0-dev zlib1g-dev ffmpeg

# Fedora
sudo dnf install gcc make autoconf automake libtool pkgconf-pkg-config gtk-doc intltool \
     glib2-devel libplist-devel sqlite-devel libxml2-devel gdk-pixbuf2-devel zlib-devel ffmpeg
```

**Gate 0.** All five commands print a version, and:

```bash
pkg-config --exists glib-2.0 gobject-2.0 gmodule-2.0 sqlite3 libplist-2.0 libxml-2.0 gdk-pixbuf-2.0 \
  && echo "all present"
```

## Stage 1 — libgpod

`Scripts/build-libgpod.sh` is macOS-specific (it hardcodes Homebrew prefixes and arch handling).
On Linux, drive autotools directly:

```bash
cd core/libgpod
[ -f configure ] || autoreconf -fi
./configure --disable-udev --disable-pygobject --disable-more-warnings
make -j"$(nproc)"
```

`--disable-more-warnings` is load-bearing for the same reason as on macOS: vendoring the git tree
trips configure's "you are a libgpod developer" heuristic, which adds `-Werror` flags a 2007
codebase cannot satisfy under a modern compiler.

**Gate 1**, and the second line is the one that matters:

```bash
ls -la core/libgpod/src/.libs/libgpod.a core/libgpod/src/.libs/libgpod.so 2>/dev/null
grep -E '^#define (HAVE_GDKPIXBUF|HAVE_LIBXML)' core/libgpod/config.h
```

`HAVE_GDKPIXBUF` **must** be present. Without it libgpod builds and runs perfectly and writes no
artwork — a silent failure the macOS build already guards against by failing the build. If it is
missing, `gdk-pixbuf-2.0` did not resolve; fix that rather than proceeding.

`HAVE_LIBXML` missing means `SysInfoExtended` is not parsed, which means no FireWire GUID, which
means every connect looks like a new device to `DeviceProfileStore`. Also fix rather than proceed.

## Stage 2 — compile the shared C

The whole point of the `core/` extraction. No app, no UI — one translation unit and a link.

```bash
gcc -c core/ipod-api/ipod-api.c -o /tmp/ipod-api.o \
    -I core/ipod-api -I core/libgpod/src -I core/libgpod \
    $(pkg-config --cflags glib-2.0 gobject-2.0)
```

**Gate 2.** It compiles with no errors, and:

```bash
nm /tmp/ipod-api.o | grep -c ' T ipod_'    # expect ~26
```

Warnings are worth reading but are not a gate. Report any that name a POSIX function — that would
contradict the finding that this file needs no shimming, and is a genuine surprise worth stopping
on.

## Stage 3 — read a real iPod

A CLI in `linux/` that links `core/` and prints what it finds. **Read-only.** Nothing writes to a
device until Stage 5.

Minimum it must do: open a mounted iPod by path, report the device info
(`ipod_get_device_info`), and list tracks with artist, album, title and track ID.

**Gate 3.** Against a real iPod, on the same device tested on macOS:

- track count matches what the macOS app reports for that iPod
- playlist count matches
- the UUID reported matches the one in the macOS General tab — this is the FireWire GUID, and it
  proves `HAVE_LIBXML` is really working
- a spot-check of five tracks shows correct artist/album/title, including at least one with an
  accented character, which exercises the NFC handling at the C boundary

## Stage 4 — parity with macOS, before any UI

The rules that must not diverge between platforms, because a divergence corrupts an iPod rather
than looking slightly different. `CLAUDE.md` is explicit that `TrackKey` drives the sync diff, the
"new music" dots and playlist resolution, and that the three must agree.

Generate vectors on the Mac, assert on Linux. Cover at least:

| Vector | Why |
|---|---|
| `TrackKey` for accented, NFD-vs-NFC, mixed-case and whitespace-padded names | The iPod stores no paths; this is the only identity. A mismatch means duplicates or silent skips |
| `LibraryScanner.parseFilename` on tracks with and without numbers, with dashes and underscores | Mirrors the C-side `parse_track_filename`; drift means wrong titles |
| `SourceFormat.needsConversion` across all four ceilings for a grid of rate/depth/lossless/HE-AAC | This is the hardware-safety contract |
| `ConversionCeiling.encodeRate` for 44.1/48/88.2/96/192 and 0 | 96→48 and 88.2→44.1 are exact halvings on purpose |

**Gate 4.** Every vector matches byte-for-byte. Any mismatch is a stop, not a note.

## Stage 5 — writing to a device

**Back up first, without exception.** A half-written iTunesDB destroys the library on the device.

```bash
cp -a /path/to/ipod/iPod_Control/iTunes ~/ipod-itunes-backup-$(date +%s)
```

Use the least precious iPod available. Test in this order, checking the device's own screen after
each: add one track → save → verify on device; add one track with artwork → verify the cover
appears; remove one track → verify; create a playlist → verify.

**Gate 5.** The iPod plays a track added by the Linux build, and shows its cover art. Nothing
below the C layer is trusted until this passes.

## Stage 6 — conversion, and the one finding that does not transfer

Reproducing the quality ladder is not optional — see the trap section above. What needs
*measuring* rather than porting is the encoder.

`agent_space/ipod-test-files/results.txt` holds the macOS bench results (tests A–F) that the four
`ConversionCeiling` rungs correspond to. Produce the same matrix with ffmpeg, and play each one
**in full, on real hardware**, not as a short clip:

- AAC at 44.1 and 48 kHz, ALAC at 44.1 and 48 kHz
- a 96 kHz and a 192 kHz source, which must always be converted
- an HE-AAC source, which must never be passed through
- a long album — the original macOS finding was *intermittent skipping across a full album*, and a
  short clip playing correctly cannot disprove it

**Gate 6.** No skipping, and seeking works within a track. Seeking is the specific thing `-s 2`
exists to protect on macOS and the specific thing ffmpeg's encoder gives no direct equivalent for.
If seeking misbehaves, the encoder settings are wrong — do not relax the ceiling to compensate.

## Stage 7 — the UI spike

Only now, and time-boxed. Two questions, in order:

1. Can a Swift package on this host link `core/` and open a real iPod? Near-certain, and it is the
   whole payoff of the extraction.
2. Can it draw a window and list those tracks? This is the actual risk — the Swift GTK bindings
   are immature and need evaluating rather than assuming.

**Gate 7.** A window listing real tracks from a real device. If 1 passes and 2 fails, that is a
result, not a failure: it settles the Option A / Option B question from Part 4 with evidence, and
`core/` is verified on Linux either way.

## What to report back

For every gate: the command and its actual output, not a paraphrase. Plus, once, the Stage 0
version block — most cross-platform failures are explained by a version somewhere in it.

Where something fails, the useful thing is the sequence around it. A missing step usually
identifies the break faster than the error text does.

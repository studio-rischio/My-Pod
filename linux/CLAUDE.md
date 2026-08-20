# CLAUDE.md — Linux

Guidance for working on the Linux port. **The repository root `CLAUDE.md` describes the macOS
build and does not apply here** — `./build.sh`, Xcode, `.xcconfig`, Homebrew and `afconvert` are
all macOS-only. Read it for the *reasoning* behind the design rules below, never for build steps.

Start at [PORTING.md](PORTING.md). It has the plan and the verification gates; work through them
in order and don't start a stage until the previous gate passes.

## What this repository is

A native macOS app that syncs music to click-wheel iPods by linking a vendored, modified fork of
**libgpod** (LGPL 2.1+). App code is MIT. The Linux port reuses exactly one thing — the C in
`core/` — and none of the Swift.

```
core/ipod-api/   MIT C shim over libgpod's public API. Shared. Compiles unmodified on Linux.
core/libgpod/    Vendored libgpod fork (LGPL). Shared. Do not edit.
My Pod/          macOS app (Swift + SwiftUI). Not shared, not built here.
linux/           This port.
windows/         A later port. Not started.
```

## Rules that are not negotiable

**Don't edit `core/libgpod/`.** It's an upstream fork; diffs against upstream matter, and it's
LGPL. Build it, don't change it.

**`core/ipod-api/ipod-api.c` is MIT and must stay that way.** It calls libgpod's public API and
includes `itdb.h`, but contains no libgpod code. Never copy implementation out of `core/libgpod/`
into it. Portability edits are fine; carrying LGPL code across that line is not.

**Back up before writing to any iPod.** A half-written iTunesDB destroys the library on the
device, and there is no undo.

```bash
cp -a /path/to/ipod/iPod_Control/iTunes ~/ipod-itunes-backup-$(date +%s)
```

**Never leave a path that mutates the database without saving.** Cancelling must finish the
in-flight track and then save. This is why the macOS sync engine has a save on every exit path.

**Guaranteed playback beats maximum quality.** When a format decision is ambiguous, convert. The
thresholds are deliberately tighter than the hardware is documented to accept because the failure
modes are asymmetric: an unnecessary re-encode costs a little quality on a device whose output
stage is 16-bit anyway, while a file that turns out to be unplayable is a silent skip on hardware
with no error reporting, where the user cannot tell the app was involved. **Do not relax a
threshold to recover quality.** Relaxing one requires evidence of the *absence* of failure across
full-length material on multiple models — not the presence of success in a short clip.

**Two rules hold at every quality rung**: 96 and 192 kHz are always converted, and HE-AAC is never
passed through. Click-wheel decoders predate SBR, so HE-AAC plays audibly wrong rather than merely
over-spec.

**The rules must not diverge from macOS.** `TrackKey`, the filename parser,
`SourceFormat.needsConversion` and `ConversionCeiling.encodeRate` decide what is the same track,
what gets converted and to what. A divergence corrupts an iPod rather than looking slightly
different. Stage 4 of PORTING.md exists to prove parity with generated vectors; treat a mismatch
there as a stop.

## Things that will bite

**`track->tracklen` must be non-zero** or the iPod silently skips the track.

**Artwork ordering**: `itdb_track_set_thumbnails` must run *before* `itdb_track_add`. libgpod
renders the thumbnail bytes lazily during `itdb_write`, so the source image file must still exist
at save time.

**Track identity is `(artist, album, title)`**, NFC-normalized, trimmed, lowercased. The iPod
database stores no source paths, so this is the only thing both sides share. File paths are
deliberately *not* NFC-normalized — the filesystem wants what it wants.

**libgpod configure flags**: `--disable-udev --disable-pygobject --disable-more-warnings`. The
last is load-bearing — vendoring the git tree trips configure's "you are a libgpod developer"
heuristic, which adds `-Werror` flags a 2007 codebase can't satisfy under a modern compiler.

**Check `config.h` after configuring.** `HAVE_GDKPIXBUF` missing means artwork is silently
dropped — builds fine, runs fine, writes no covers. `HAVE_LIBXML` missing means
`SysInfoExtended` isn't parsed, so there's no FireWire GUID and every connect looks like a new
device. Both are silent. Gate 1 checks them.

## Library layout the app expects

Plex-style `Root/Artist/Album/Track`. Track number and title are parsed from the filename, mirroring
the C-side `parse_track_filename`. There is no metadata layer — tags in the audio files are ignored
except as a source of embedded cover art.

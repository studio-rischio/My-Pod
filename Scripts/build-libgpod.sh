#!/bin/bash
#
# Build the vendored libgpod into a static library.
#
# My Pod links Vendor/libgpod/src/.libs/libgpod.a and includes headers from
# Vendor/libgpod/src. This script is the only thing that produces them — it's
# invoked from the top-level build.sh and from the app target's "Build libgpod"
# run-script phase, both of which skip it when the .a is already present.
#
# Only ./configure is generated here; libgpod's own Makefiles do the rest, so
# re-running this after a source change is cheap (make is incremental).
#
# Architectures
# -------------
# Set ARCHS to build more than the host's. The result at $LIBGPOD_A is a fat
# archive covering everything requested, so the xcconfig can name one path
# regardless of what the app is being built for — the linker takes the slice it
# needs and ignores the rest.
#
# libgpod's configure refuses to run in a VPATH build while the source tree is
# already configured, and distclean wipes src/.libs along with everything else,
# so the two architectures can't be built side by side and can't leave their
# output where it lands. Each arch is therefore built in turn and its archive
# copied out to Vendor/libgpod-arch/ first. That directory is also the cache:
# an arch whose archive is already there is never rebuilt, so adding x86_64
# later doesn't re-do arm64, and switching back doesn't re-do x86_64.
#
# Usage:
#   ./Scripts/build-libgpod.sh                     # host arch only
#   ARCHS="arm64 x86_64" ./Scripts/build-libgpod.sh  # both, as a fat archive
#   ./Scripts/build-libgpod.sh --force             # rebuild, discarding the cache
#   ./Scripts/build-libgpod.sh clean               # remove build output
#
# Prerequisites (Homebrew):
#   brew install autoconf automake libtool gtk-doc intltool glib pkg-config
#
# Cross-compiling to x86_64 additionally needs the staged Intel libraries; this
# script invokes Scripts/fetch-intel-deps.sh itself when they're missing.

set -e
cd "$(dirname "$0")/.."

ROOT="$PWD"
LIBGPOD_DIR="Vendor/libgpod"
LIBGPOD_A="$LIBGPOD_DIR/src/.libs/libgpod.a"
ARCH_CACHE="$ROOT/Vendor/libgpod-arch"
INTEL_PREFIX="$ROOT/Vendor/intel-deps"

HOST_ARCH="$(uname -m)"
ARCHS="${ARCHS:-$HOST_ARCH}"

# Matches the app's MACOSX_DEPLOYMENT_TARGET. Without it these objects are built
# for whatever macOS is running, and linking them into an app that targets
# something older warns on every single .o.
MIN_MACOS="14.0"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
step() { printf "${GREEN}==>${NC} %s\n" "$1"; }
fail() { printf "${RED}Error:${NC} %s\n" "$1" >&2; exit 1; }

# udev is Linux-only; the Python bindings need pygobject and we don't use them.
#
# --disable-more-warnings is load-bearing. libgpod's configure.ac decides
# whether to add `-Wall -Werror -Wcast-align …` by testing for autogen.sh —
# its stand-in for "this is a git checkout, so the builder is a libgpod
# developer". Vendoring the git tree trips that heuristic, and a 2007 codebase
# does not compile clean under a 2026 clang (itdb_thumb.c, itdb_artwork.c,
# db-artwork-writer.c and ithumb-writer.c all fail on -Wcast-align alone).
# We consume libgpod rather than develop it, so its warnings shouldn't be
# errors here.
CONFIGURE_FLAGS=(--disable-udev --disable-pygobject --disable-more-warnings)

case "${1:-build}" in
    clean)
        step "Cleaning libgpod build output..."
        if [ -f "$LIBGPOD_DIR/Makefile" ]; then
            make -C "$LIBGPOD_DIR" distclean >/dev/null 2>&1 || true
        fi
        # distclean leaves the autogen-generated files behind; drop them too so
        # the tree matches a fresh checkout.
        rm -rf "$LIBGPOD_DIR"/{configure,config.status,config.log,libtool,aclocal.m4,autom4te.cache}
        rm -rf "$ARCH_CACHE"
        echo "Clean complete."
        exit 0
        ;;
    --force)
        rm -f "$LIBGPOD_A"
        rm -rf "$ARCH_CACHE"
        ;;
    build)
        ;;
    *)
        fail "Unknown command: $1 (expected: build | --force | clean)"
        ;;
esac

# Already done if the existing archive covers every requested architecture.
if [ -f "$LIBGPOD_A" ]; then
    present="$(lipo -archs "$LIBGPOD_A" 2>/dev/null || echo '')"
    missing=""
    for arch in $ARCHS; do
        case " $present " in *" $arch "*) ;; *) missing="$missing $arch" ;; esac
    done
    if [ -z "$missing" ]; then
        step "libgpod.a already covers:$(printf ' %s' $ARCHS) — skipping. (--force to rebuild)"
        exit 0
    fi
    step "libgpod.a has [$present ] but needs$missing — rebuilding."
fi

[ -d "$LIBGPOD_DIR" ] || fail "$LIBGPOD_DIR not found. Vendored libgpod is missing from the checkout."

step "Checking prerequisites..."
command -v pkg-config >/dev/null 2>&1 || fail "pkg-config not found. Install with: brew install pkg-config"
pkg-config --exists glib-2.0 || fail "glib-2.0 not found. Install with: brew install glib"

# Only ./configure needs the autotools; once it exists a plain checkout can
# rebuild without them.
if [ ! -f "$LIBGPOD_DIR/configure" ]; then
    for tool in autoreconf autoconf automake glibtoolize gtkdocize intltoolize; do
        command -v "$tool" >/dev/null 2>&1 || \
            fail "$tool not found (needed to generate libgpod's configure). Install with: brew install autoconf automake libtool gtk-doc intltool"
    done
fi

pushd "$LIBGPOD_DIR" >/dev/null
if [ ! -f configure ]; then
    # Deliberately NOT libgpod's own ./autogen.sh — it probes for versioned
    # binaries (automake-1.7 … automake-1.13) that Homebrew doesn't install,
    # so it fails outright against automake 1.18. autoreconf does the same job
    # and works with current autotools.
    step "Generating build system (autoreconf)..."
    autoreconf -fi
fi
popd >/dev/null

mkdir -p "$ARCH_CACHE"

build_one_arch() {
    local arch="$1"
    local cached="$ARCH_CACHE/libgpod-$arch.a"

    if [ -f "$cached" ]; then
        step "libgpod for $arch already cached — reusing."
        return
    fi

    # Every arch starts from a clean tree: configure caches the compiler and its
    # answers in config.status, and reusing them across architectures produces
    # an archive that claims one arch and contains another.
    step "Configuring libgpod for $arch..."
    pushd "$LIBGPOD_DIR" >/dev/null
    make distclean >/dev/null 2>&1 || true

    if [ "$arch" = "$HOST_ARCH" ]; then
        CC="clang -arch $arch -mmacosx-version-min=$MIN_MACOS" \
            ./configure "${CONFIGURE_FLAGS[@]}" >/dev/null
    else
        # Cross-compiling. PKG_CONFIG_LIBDIR (not just PKG_CONFIG_PATH) so a
        # miss in the staged prefix fails loudly instead of silently resolving
        # against the host's arm64 Homebrew and linking the wrong architecture.
        PKG_CONFIG_PATH="$INTEL_PREFIX/lib/pkgconfig" \
        PKG_CONFIG_LIBDIR="$INTEL_PREFIX/lib/pkgconfig" \
        CC="clang -arch $arch -mmacosx-version-min=$MIN_MACOS" \
            ./configure \
                --host="$arch-apple-darwin" \
                --build="$HOST_ARCH-apple-darwin" \
                "${CONFIGURE_FLAGS[@]}" >/dev/null
    fi

    # Artwork is optional in libgpod and its absence is only a warning, but the
    # app calls itdb_track_set_thumbnails on every sync. A build without it
    # links, runs, and silently writes no covers — so treat it as fatal here
    # rather than discovering it on the device.
    grep -q '^#define HAVE_GDKPIXBUF' config.h \
        || fail "libgpod configured without gdk-pixbuf for $arch — artwork would be silently dropped."

    step "Building libgpod for $arch..."
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" >/dev/null

    [ -f "src/.libs/libgpod.a" ] || fail "Build finished but src/.libs/libgpod.a was not produced for $arch."
    local got
    got="$(lipo -archs src/.libs/libgpod.a)"
    [ "$got" = "$arch" ] || fail "Built $got but expected $arch — the cross configuration didn't take."

    popd >/dev/null
    cp "$LIBGPOD_DIR/src/.libs/libgpod.a" "$cached"
    step "Cached: $cached"
}

for arch in $ARCHS; do
    if [ "$arch" != "$HOST_ARCH" ] && [ ! -f "$INTEL_PREFIX/.staged" ]; then
        step "Staging $arch dependencies first..."
        "$ROOT/Scripts/fetch-intel-deps.sh"
    fi
    build_one_arch "$arch"
done

# Combine into the single path the xcconfig names. lipo needs at least two
# inputs to make a fat file; one arch is just a copy.
inputs=""
for arch in $ARCHS; do inputs="$inputs $ARCH_CACHE/libgpod-$arch.a"; done
mkdir -p "$(dirname "$LIBGPOD_A")"
count="$(echo $ARCHS | wc -w | tr -d ' ')"
if [ "$count" -gt 1 ]; then
    step "Combining$(printf ' %s' $ARCHS) into a fat archive..."
    lipo -create $inputs -output "$LIBGPOD_A"
else
    cp $inputs "$LIBGPOD_A"
fi

[ -f "$LIBGPOD_A" ] || fail "Build finished but $LIBGPOD_A was not produced."
step "Built: $LIBGPOD_A [$(lipo -archs "$LIBGPOD_A")]"

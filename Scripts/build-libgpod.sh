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
# Usage:
#   ./Scripts/build-libgpod.sh          # configure + make if libgpod.a is missing
#   ./Scripts/build-libgpod.sh --force  # rebuild even if libgpod.a exists
#   ./Scripts/build-libgpod.sh clean    # remove build output
#
# Prerequisites (Homebrew):
#   brew install autoconf automake libtool gtk-doc intltool glib pkg-config

set -e
cd "$(dirname "$0")/.."

LIBGPOD_DIR="Vendor/libgpod"
LIBGPOD_A="$LIBGPOD_DIR/src/.libs/libgpod.a"

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
        echo "Clean complete."
        exit 0
        ;;
    --force)
        rm -f "$LIBGPOD_A"
        ;;
    build)
        ;;
    *)
        fail "Unknown command: $1 (expected: build | --force | clean)"
        ;;
esac

if [ -f "$LIBGPOD_A" ]; then
    step "libgpod.a already built — skipping. (--force to rebuild)"
    exit 0
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
if [ ! -f Makefile ]; then
    step "Running configure..."
    ./configure "${CONFIGURE_FLAGS[@]}"
fi
step "Building libgpod..."
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
popd >/dev/null

[ -f "$LIBGPOD_A" ] || fail "Build finished but $LIBGPOD_A was not produced."
step "Built: $LIBGPOD_A"

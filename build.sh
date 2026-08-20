#!/bin/bash
#
# Build "My Pod" — ensures the C deps (libgpod + libipod-api) are built,
# then builds the macOS app via xcodebuild and launches it.
#
# Usage:
#   ./build.sh           # build deps if needed, build app, launch it
#   ./build.sh build     # same, but don't launch
#   ./build.sh clean     # clean app build + C deps
#
# Environment:
#   CONFIG     Debug (default) or Release
#   ARCH       host architecture (default); set to x86_64 to cross-compile
#
# Cross-compiling for Intel
# -------------------------
#   ARCH=x86_64 CONFIG=Release ./build.sh build
#
# Homebrew on Apple Silicon ships arm64-only dylibs, so the Intel build links
# against a staged prefix of x86_64 Homebrew bottles instead — see
# Scripts/fetch-intel-deps.sh, which this script runs on demand. Everything the
# xcconfig needs is addressed through BREW_PREFIX, and the staged tree is shaped
# like a Homebrew prefix, so pointing that one variable elsewhere is the whole
# of the build-settings change.
#
# The two architectures get separate derived-data trees so a release can hold
# both at once; the host build keeps ./build so existing paths still work.

set -e
cd "$(dirname "$0")"

CONFIG="${CONFIG:-Debug}"
HOST_ARCH="$(uname -m)"
ARCH="${ARCH:-$HOST_ARCH}"
PROJECT="My Pod.xcodeproj"
SCHEME="My Pod"
if [ "$ARCH" = "$HOST_ARCH" ]; then
    DERIVED="./build"
else
    DERIVED="./build-$ARCH"
fi
APP_PATH="$DERIVED/Build/Products/$CONFIG/My Pod.app"
LIBGPOD_A="core/libgpod/src/.libs/libgpod.a"
INTEL_PREFIX="$PWD/Vendor/intel-deps"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step()  { printf "${GREEN}==>${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}Warning:${NC} %s\n" "$1"; }
fail()  { printf "${RED}Error:${NC} %s\n" "$1" >&2; exit 1; }

case "${1:-run}" in
    clean)
        step "Cleaning Xcode build output..."
        rm -rf ./build ./build-x86_64
        step "Cleaning libgpod build artifacts..."
        ./Scripts/build-libgpod.sh clean || true
        echo "Clean complete."
        exit 0
        ;;
    build|run)
        ;;
    *)
        fail "Unknown command: $1 (expected: build | run | clean)"
        ;;
esac

# 1. Stage the cross-compilation libraries, if this isn't a native build.
#    Cheap and idempotent: it exits immediately once the tree is there.
if [ "$ARCH" != "$HOST_ARCH" ]; then
    ./Scripts/fetch-intel-deps.sh
fi

# 2. Build the vendored libgpod if the static library doesn't cover this arch.
#    The script does its own prerequisite checks (pkg-config, glib, and the
#    autotools — the last only when ./configure still needs generating).
ARCHS="$ARCH" ./Scripts/build-libgpod.sh

# 3. Build the app. A non-native build swaps BREW_PREFIX for the staged tree and
#    pins ARCHS, since ONLY_ACTIVE_ARCH would otherwise resolve to the host's.
BUILD_SETTINGS=()
if [ "$ARCH" != "$HOST_ARCH" ]; then
    BUILD_SETTINGS=("BREW_PREFIX=$INTEL_PREFIX" "ARCHS=$ARCH" "ONLY_ACTIVE_ARCH=NO")
fi

step "Building $SCHEME ($CONFIG / $ARCH) into $DERIVED ..."
if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination "platform=macOS,arch=$ARCH" \
        -derivedDataPath "$DERIVED" \
        "${BUILD_SETTINGS[@]}" \
        build | xcbeautify --quiet
else
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination "platform=macOS,arch=$ARCH" \
        -derivedDataPath "$DERIVED" \
        "${BUILD_SETTINGS[@]}" \
        build
fi

if [ ! -d "$APP_PATH" ]; then
    fail "Build succeeded but app not found at: $APP_PATH"
fi

ACTUAL_ARCH="$(lipo -archs "$APP_PATH/Contents/MacOS/My Pod" 2>/dev/null || echo unknown)"
case " $ACTUAL_ARCH " in
    *" $ARCH "*) ;;
    *) fail "Asked for $ARCH but the binary is [$ACTUAL_ARCH]." ;;
esac

step "Built: $APP_PATH [$ACTUAL_ARCH]"

# 4. Launch (unless 'build' was passed). A cross-built app is left alone —
#    on Apple Silicon it would launch under Rosetta, which is useful for a
#    smoke test but not what someone running ./build.sh is asking for.
if [ "${1:-run}" = "run" ]; then
    if [ "$ARCH" != "$HOST_ARCH" ]; then
        warn "Not launching a $ARCH build on $HOST_ARCH. Run it manually to test under Rosetta:"
        printf "    open \"%s\"\n" "$APP_PATH"
    else
        step "Launching..."
        open "$APP_PATH"
    fi
fi

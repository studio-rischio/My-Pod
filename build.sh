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
#   ARCH       arm64 (default)
#

set -e
cd "$(dirname "$0")"

CONFIG="${CONFIG:-Debug}"
ARCH="${ARCH:-arm64}"
PROJECT="My Pod.xcodeproj"
SCHEME="My Pod"
DERIVED="./build"
APP_PATH="$DERIVED/Build/Products/$CONFIG/My Pod.app"
LIBGPOD_A="Vendor/libgpod/src/.libs/libgpod.a"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step()  { printf "${GREEN}==>${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}Warning:${NC} %s\n" "$1"; }
fail()  { printf "${RED}Error:${NC} %s\n" "$1" >&2; exit 1; }

case "${1:-run}" in
    clean)
        step "Cleaning Xcode build output ($DERIVED)..."
        rm -rf "$DERIVED"
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

# 1. Build the vendored libgpod if the static library isn't there yet.
#    The script does its own prerequisite checks (pkg-config, glib, and the
#    autotools — the last only when ./configure still needs generating).
./Scripts/build-libgpod.sh

# 2. Build the app.
step "Building $SCHEME ($CONFIG / $ARCH) into $DERIVED ..."
if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination "platform=macOS,arch=$ARCH" \
        -derivedDataPath "$DERIVED" \
        build | xcbeautify --quiet
else
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination "platform=macOS,arch=$ARCH" \
        -derivedDataPath "$DERIVED" \
        build
fi

if [ ! -d "$APP_PATH" ]; then
    fail "Build succeeded but app not found at: $APP_PATH"
fi

step "Built: $APP_PATH"

# 3. Launch (unless 'build' was passed).
if [ "${1:-run}" = "run" ]; then
    step "Launching..."
    open "$APP_PATH"
fi

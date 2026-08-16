#!/bin/bash
#
# Make a built "My Pod.app" self-contained so it runs on Macs without Homebrew.
#
# Only libgpod is statically linked. The app still links six Homebrew dylibs by
# absolute path, which pull four more transitively, so a freshly built .app dies
# at launch with "Library not loaded" on any machine that lacks them.
#
# This script walks the dependency graph, copies every non-system dylib into
# Contents/Frameworks, rewrites the load commands to @rpath, and re-signs.
# Rewriting load commands invalidates the existing signature, so the re-sign at
# the end is mandatory, not cosmetic.
#
# Architecture-agnostic by construction: it follows whatever the binary actually
# references. For the arm64 build that's /opt/homebrew/opt/...; for the Intel
# build it's Vendor/intel-deps/lib/..., staged by Scripts/fetch-intel-deps.sh.
# Both are absolute paths outside /usr/lib, which is the only property the walk
# below cares about. Run it once per architecture, on each built .app.
#
# Note on gdk-pixbuf: its PNG and JPEG decoders are compiled into
# libgdk_pixbuf itself (Homebrew ships no external loader for either), and
# ArtworkLocator only ever reads jpg/jpeg/png. So the loaders directory and
# loaders.cache do NOT need bundling. If artwork ever gains a format that is an
# external loader (gif, tiff, bmp...), that stops being true.
#
# Usage:
#   ./Scripts/bundle-app.sh [path/to/My Pod.app]
#
# Defaults to the Release build produced by `CONFIG=Release ./build.sh build`.

set -e
cd "$(dirname "$0")/.."

APP="${1:-build/Build/Products/Release/My Pod.app}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
step() { printf "${GREEN}==>${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}Warning:${NC} %s\n" "$1"; }
fail() { printf "${RED}Error:${NC} %s\n" "$1" >&2; exit 1; }

[ -d "$APP" ] || fail "App not found: $APP (build it first with: CONFIG=Release ./build.sh build)"

BINARY="$APP/Contents/MacOS/My Pod"
FRAMEWORKS="$APP/Contents/Frameworks"
[ -f "$BINARY" ] || fail "Executable not found: $BINARY"

mkdir -p "$FRAMEWORKS"

# A dependency needs bundling when it's an absolute path outside the OS. Paths
# under /usr/lib and /System ship with macOS; anything else (Homebrew, /usr/local)
# does not. @rpath/@loader_path/@executable_path entries are already relative to
# the bundle and are left alone.
needs_bundling() {
    case "$1" in
        /usr/lib/*|/System/*) return 1 ;;
        /*)                   return 0 ;;
        *)                    return 1 ;;
    esac
}

# Dependencies of a Mach-O, excluding its own install name. `otool -L` lists a
# dylib's own id as the first entry, which must not be treated as a dependency.
deps_of() {
    local bin="$1" id
    id="$(otool -D "$bin" 2>/dev/null | tail -n +2)"
    otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
        [ "$dep" = "$id" ] && continue
        echo "$dep"
    done
}

step "Bundling dependencies of $(basename "$APP")..."

# Breadth-first walk: copied dylibs have dependencies of their own (glib pulls
# in libintl and pcre2, gobject pulls in libffi), so each newly copied file goes
# back on the queue.
queue=("$BINARY")
copied=""
head=0

while [ $head -lt ${#queue[@]} ]; do
    current="${queue[$head]}"
    head=$((head + 1))

    while read -r dep; do
        [ -z "$dep" ] && continue
        needs_bundling "$dep" || continue

        base="$(basename "$dep")"
        target="$FRAMEWORKS/$base"

        if [ ! -f "$target" ]; then
            if [ ! -f "$dep" ]; then
                warn "missing on this machine, skipping: $dep"
                continue
            fi
            cp "$dep" "$target"
            # Homebrew installs dylibs read-only; install_name_tool needs write.
            chmod u+w "$target"
            install_name_tool -id "@rpath/$base" "$target" 2>/dev/null
            copied="$copied $base"
            queue+=("$target")
            printf "    + %s\n" "$base"
        fi

        # Repoint the referring binary at the bundled copy.
        install_name_tool -change "$dep" "@rpath/$base" "$current" 2>/dev/null
    done <<< "$(deps_of "$current")"
done

# Teach the executable where Frameworks lives. Harmless if already present.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY" 2>/dev/null || true

# Drop the Homebrew rpaths the xcconfig adds for local development. They are
# searched in order, ahead of the bundle, so on a machine that does have
# Homebrew an @rpath/libglib-2.0.0.dylib would resolve to *their* copy rather
# than the one we just bundled — and an incompatible version crashes at launch.
# Everything is bundled by this point, so the external paths are pure risk.
step "Removing Homebrew rpaths so the bundle is hermetic..."
while read -r rp; do
    [ -z "$rp" ] && continue
    case "$rp" in
        /usr/lib/*|/System/*|@*) continue ;;
    esac
    install_name_tool -delete_rpath "$rp" "$BINARY" 2>/dev/null && printf "    - %s\n" "$rp"
done <<< "$(otool -l "$BINARY" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')"

step "Re-signing (rewriting load commands invalidated the signature)..."
# Nested code first, bundle last — signing the app seals what's inside it.
for dylib in "$FRAMEWORKS"/*.dylib; do
    [ -f "$dylib" ] || continue
    codesign --force --sign - --timestamp=none "$dylib" 2>/dev/null
done
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null

step "Verifying no external paths remain..."
leaks=0
while read -r bin; do
    while read -r dep; do
        [ -z "$dep" ] && continue
        if needs_bundling "$dep"; then
            printf "${RED}    LEAK${NC} %s -> %s\n" "$(basename "$bin")" "$dep"
            leaks=$((leaks + 1))
        fi
    done <<< "$(deps_of "$bin")"
done <<< "$(find "$APP/Contents/MacOS" "$FRAMEWORKS" -type f -perm +111 2>/dev/null)"

[ "$leaks" -eq 0 ] || fail "$leaks unbundled dependency reference(s) remain — the app will not launch elsewhere."

codesign --verify --deep --strict "$APP" 2>/dev/null || fail "Code signature verification failed."

step "Bundled:$copied"
step "Self-contained: $APP"

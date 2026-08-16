#!/bin/bash
#
# Stage x86_64 copies of the Homebrew libraries My Pod links against.
#
# Why this exists: Homebrew on Apple Silicon installs arm64-only dylibs, so an
# Intel build has nothing to link. The obvious fix — a second Homebrew under
# /usr/local via Rosetta — means building glib and its dependencies from source,
# because Homebrew no longer produces Intel bottles for current macOS. But it
# still *hosts* the last ones it built, tagged `sonoma` (Homebrew's Intel tags
# carry no arch prefix; `arm64_sonoma` is the Apple Silicon one). Those are
# real, signed, minos-14.0 x86_64 builds, and downloading them takes seconds
# rather than an hour of compiling under emulation.
#
# Bottles are relocatable: paths inside them are the literal strings
# @@HOMEBREW_PREFIX@@ and @@HOMEBREW_CELLAR@@, which Homebrew rewrites on
# install. Nothing here is installed, so this script does that rewriting itself
# — in the .pc files as text, and in the dylibs as load commands — pointing
# everything at the staging prefix. After that the tree links like an ordinary
# Homebrew prefix, and bundle-app.sh treats the absolute paths exactly as it
# treats /opt/homebrew ones.
#
# Usage:
#   ./Scripts/fetch-intel-deps.sh          # download + stage if missing
#   ./Scripts/fetch-intel-deps.sh --force  # re-download and re-stage
#   ./Scripts/fetch-intel-deps.sh clean    # remove the staged tree

set -e
cd "$(dirname "$0")/.."

PREFIX="$PWD/Vendor/intel-deps"
CACHE="$PREFIX/.bottles"
STAMP="$PREFIX/.staged"

# The transitive set the app actually loads. glib supplies gobject, gmodule and
# gio in the same bottle; libpng and jpeg-turbo arrive via gdk-pixbuf, whose
# PNG/JPEG decoders are compiled in but still link the codecs dynamically.
#
# The tail of this list — libtiff and below — is not linked by anything the app
# calls. It's here because gdk-pixbuf-2.0.pc names libtiff-4 in Requires, and
# pkg-config resolves Requires transitively before it will answer at all. Drop
# them and libgpod's configure silently reports "gdkpixbuf support is disabled",
# which builds fine and then writes no artwork to the iPod.
FORMULAE=(
    glib gettext pcre2 libffi libplist gdk-pixbuf libpng jpeg-turbo
    libtiff webp xz zstd lz4
)

# Homebrew's Intel bottle tag. Newer tags (sequoia, tahoe) are Apple Silicon
# only for most of these formulae, so this is the newest one that exists across
# the whole set. It sets the effective floor for MACOSX_DEPLOYMENT_TARGET.
TAG="sonoma"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { printf "${GREEN}==>${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}Warning:${NC} %s\n" "$1"; }
fail() { printf "${RED}Error:${NC} %s\n" "$1" >&2; exit 1; }

case "${1:-build}" in
    clean)
        step "Removing $PREFIX..."
        rm -rf "$PREFIX"
        echo "Clean complete."
        exit 0
        ;;
    --force) rm -rf "$PREFIX" ;;
    build)   ;;
    *)       fail "Unknown command: $1 (expected: build | --force | clean)" ;;
esac

if [ -f "$STAMP" ]; then
    step "Intel dependencies already staged — skipping. (--force to re-fetch)"
    exit 0
fi

command -v python3 >/dev/null 2>&1 || fail "python3 not found (needed to read the Homebrew API)."

mkdir -p "$CACHE" "$PREFIX/lib" "$PREFIX/include"

# ghcr.io serves Homebrew's bottles and wants a bearer token even for anonymous
# reads; "QQ==" is the literal placeholder Homebrew itself sends.
fetch_bottle() {
    local formula="$1" url sha out
    read -r url sha < <(curl -fsS "https://formulae.brew.sh/api/formula/$formula.json" | python3 -c "
import json,sys
files = json.load(sys.stdin)['bottle']['stable']['files']
f = files.get('$TAG')
if not f:
    sys.exit('no $TAG bottle for $formula (have: %s)' % ', '.join(files))
print(f['url'], f['sha256'])
") || fail "Could not resolve an Intel bottle for $formula."

    out="$CACHE/$formula.tar.gz"
    if [ ! -f "$out" ]; then
        curl -fsSL -H "Authorization: Bearer QQ==" -o "$out" "$url" \
            || fail "Download failed for $formula."
    fi

    local got
    got="$(shasum -a 256 "$out" | awk '{print $1}')"
    [ "$got" = "$sha" ] || fail "Checksum mismatch for $formula (got $got, want $sha)."
    printf "    + %-14s %s\n" "$formula" "$(du -h "$out" | awk '{print $1}')"
}

step "Downloading Intel ($TAG) bottles..."
for f in "${FORMULAE[@]}"; do fetch_bottle "$f"; done

# Bottles unpack as <formula>/<version>/{lib,include,share,...}. Flatten them
# into one prefix so a single -I/-L pair covers everything, the way a real
# Homebrew prefix does.
step "Staging into $PREFIX..."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for f in "${FORMULAE[@]}"; do
    tar -xzf "$CACHE/$f.tar.gz" -C "$WORK"
done
for cellar in "$WORK"/*/*/; do
    [ -d "$cellar" ] || continue
    for sub in lib include share bin; do
        [ -d "$cellar/$sub" ] || continue
        mkdir -p "$PREFIX/$sub"
        # -a to keep symlinks (libglib-2.0.dylib -> libglib-2.0.0.dylib) as
        # links rather than copying the target over its own alias.
        cp -a "$cellar/$sub/." "$PREFIX/$sub/" 2>/dev/null || true
    done
done

# Rewrite the relocation placeholders. @@HOMEBREW_PREFIX@@/opt/<formula>/lib and
# @@HOMEBREW_CELLAR@@/<formula>/<version>/lib both collapse to $PREFIX/lib here,
# because the flatten above discarded the per-formula directories.
step "Rewriting bottle placeholders to the staging prefix..."
# Not every path in a bottle is a placeholder. Intel bottles are built for
# /usr/local, and a few .pc files bake that in literally rather than going
# through @@HOMEBREW_PREFIX@@ — gdk-pixbuf-2.0.pc is one, which is how an
# unrewritten -I/usr/local/include/gdk-pixbuf-2.0 reaches the compiler and
# gdk-pixbuf.h "isn't found" despite being right there. On an Intel Homebrew
# /usr/local *is* the prefix, so every such reference belongs to Homebrew and
# rewrites the same way.
while IFS= read -r pc; do
    /usr/bin/sed -i '' \
        -e "s|@@HOMEBREW_CELLAR@@/[^/]*/[^/]*|$PREFIX|g" \
        -e "s|@@HOMEBREW_PREFIX@@/opt/[^/]*|$PREFIX|g" \
        -e "s|@@HOMEBREW_PREFIX@@|$PREFIX|g" \
        -e "s|/usr/local/opt/[^/]*|$PREFIX|g" \
        -e "s|/usr/local/Cellar/[^/]*/[^/]*|$PREFIX|g" \
        -e "s|/usr/local|$PREFIX|g" \
        "$pc"
done <<< "$(find "$PREFIX/lib/pkgconfig" -name '*.pc' 2>/dev/null)"

# Same substitution in Mach-O load commands. Every dylib's own id and each of
# its @@-prefixed dependencies become absolute paths in the staging prefix, so
# the linker resolves them and bundle-app.sh later sees ordinary absolute paths
# outside /usr/lib — exactly the shape it already knows how to bundle.
rewrote=0
while IFS= read -r lib; do
    [ -f "$lib" ] || continue          # skip the symlink aliases
    [ -L "$lib" ] && continue
    base="$(basename "$lib")"
    chmod u+w "$lib"
    install_name_tool -id "$PREFIX/lib/$base" "$lib" 2>/dev/null || true
    while IFS= read -r dep; do
        case "$dep" in
            @@HOMEBREW_*) ;;
            *) continue ;;
        esac
        install_name_tool -change "$dep" "$PREFIX/lib/$(basename "$dep")" "$lib" 2>/dev/null || true
    done <<< "$(otool -L "$lib" 2>/dev/null | tail -n +2 | awk '{print $1}')"
    # install_name_tool invalidates the bottle's ad-hoc signature, and an
    # unsigned x86_64 dylib won't load under Rosetta.
    codesign --force --sign - --timestamp=none "$lib" 2>/dev/null || true
    rewrote=$((rewrote + 1))
done <<< "$(find "$PREFIX/lib" -name '*.dylib')"
printf "    %d dylibs rewritten and re-signed\n" "$rewrote"

# libgpod's configure does PKG_CHECK_MODULES(... sqlite3 ...), but sqlite3 is a
# macOS system library with no bottle and no .pc file of its own — Homebrew
# papers over this with a private shim under Library/Homebrew/os/mac/pkgconfig/,
# whose path is pinned to the macOS major version. Rather than reach into
# Homebrew's internals, generate an equivalent. It's arch-neutral: -lsqlite3
# resolves through the SDK's .tbd stubs, which carry every slice.
step "Writing pkg-config shims for macOS system libraries..."
SDK="$(xcrun --show-sdk-path)"
# name|version|link flags|extra include subdir
SYSTEM_LIBS=(
    "sqlite3|$(/usr/bin/sqlite3 --version 2>/dev/null | awk '{print $1}')|-lsqlite3|"
    "libxml-2.0|2.9.13|-lxml2|libxml2"
    "zlib|1.2.12|-lz|"
)
for entry in "${SYSTEM_LIBS[@]}"; do
    IFS='|' read -r name version libs incdir <<< "$entry"
    cflags=""
    [ -n "$incdir" ] && cflags="-I\${includedir}/$incdir"
    cat > "$PREFIX/lib/pkgconfig/$name.pc" <<PC
# Generated by Scripts/fetch-intel-deps.sh. $name ships with macOS, so there is
# no bottle to stage — these flags resolve against the SDK, whose .tbd stubs
# carry every architecture, making this file arch-neutral.
prefix=$SDK/usr
includedir=\${prefix}/include

Name: $name
Description: macOS system library
Version: ${version:-1.0.0}
Libs: $libs
Cflags: $cflags
PC
done

# The xcconfig addresses Homebrew as $(BREW_PREFIX)/opt/<formula>/{include,lib},
# which is Homebrew's per-formula symlink farm. Reproducing that shape here means
# an Intel build needs no new build settings at all — BREW_PREFIX just points
# somewhere else. Each opt/<formula> is a relative link back to the flattened
# prefix, so opt/glib/lib and opt/gettext/lib both resolve to the same lib dir.
step "Adding opt/ aliases so the tree is shaped like a Homebrew prefix..."
mkdir -p "$PREFIX/opt"
for f in "${FORMULAE[@]}"; do
    ln -sfn .. "$PREFIX/opt/$f"
done

step "Verifying the staged tree is x86_64 and self-consistent..."
problems=0
for want in libglib-2.0.0 libgobject-2.0.0 libgmodule-2.0.0 libintl.8 libplist-2.0.4 libgdk_pixbuf-2.0.0; do
    lib="$PREFIX/lib/$want.dylib"
    if [ ! -f "$lib" ]; then
        printf "${RED}    missing${NC} %s\n" "$want.dylib"; problems=$((problems + 1)); continue
    fi
    arch="$(lipo -archs "$lib" 2>/dev/null)"
    [ "$arch" = "x86_64" ] || { printf "${RED}    wrong arch${NC} %s: %s\n" "$want" "$arch"; problems=$((problems + 1)); }
done
# Nothing may still carry an unrewritten placeholder — it would link here and
# fail to load anywhere.
while IFS= read -r lib; do
    [ -L "$lib" ] && continue
    if otool -L "$lib" 2>/dev/null | grep -qE '@@HOMEBREW|/usr/local'; then
        printf "${RED}    unrewritten prefix in${NC} %s\n" "$(basename "$lib")"
        problems=$((problems + 1))
    fi
done <<< "$(find "$PREFIX/lib" -name '*.dylib')"

# Same for the .pc files. A stale prefix here is worse than in a dylib: it
# doesn't fail the link, it silently drops a feature. An unrewritten
# gdk-pixbuf include path makes libgpod's configure report "gdkpixbuf support
# is disabled", which builds and runs perfectly and writes no artwork.
while IFS= read -r pc; do
    if grep -qE '@@HOMEBREW|/usr/local' "$pc"; then
        printf "${RED}    unrewritten prefix in${NC} %s\n" "$(basename "$pc")"
        problems=$((problems + 1))
    fi
done <<< "$(find "$PREFIX/lib/pkgconfig" -name '*.pc' 2>/dev/null)"

# The feature that silently disappears if the above goes wrong. Check it
# directly rather than trusting that the paths look right.
if ! PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
     pkg-config --exists "gdk-pixbuf-2.0 >= 2.6.0" 2>/dev/null; then
    printf "${RED}    gdk-pixbuf-2.0 does not resolve${NC} — libgpod would build without artwork support\n"
    problems=$((problems + 1))
fi
gdk_inc="$(PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
    pkg-config --cflags-only-I gdk-pixbuf-2.0 2>/dev/null | tr ' ' '\n' | sed 's/^-I//' | grep 'gdk-pixbuf-2.0$' | head -1)"
if [ ! -f "$gdk_inc/gdk-pixbuf/gdk-pixbuf.h" ]; then
    printf "${RED}    gdk-pixbuf.h not reachable${NC} via the include path pkg-config reports\n"
    problems=$((problems + 1))
fi

[ "$problems" -eq 0 ] || fail "$problems problem(s) in the staged tree."

touch "$STAMP"
step "Staged $(find "$PREFIX/lib" -name '*.dylib' -not -type l | wc -l | tr -d ' ') x86_64 dylibs in $PREFIX"

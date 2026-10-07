#!/usr/bin/env bash
#
# Builds LibRaw into a static XCFramework at vendor/build/LibRaw.xcframework.
#
# The pinned version, source URL and SHA-256 live in config/vendored-libs.json. The
# script is idempotent: a stamp file records the pinned version + SHA, and a matching
# stamp short-circuits the build.
#
# LibRaw is compiled in its reentrant configuration (no LIBRAW_NOTHREADS) so separate
# LibRaw instances may run concurrently on different threads.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/config/vendored-libs.json"
CACHE="$ROOT/vendor/cache"
BUILD="$ROOT/vendor/build"
OUTPUT="$BUILD/LibRaw.xcframework"
STAMP="$OUTPUT/.redlamp-stamp"

read_config() {
    /usr/bin/python3 -c "import json,sys; print(json.load(open('$CONFIG'))['LibRaw']['$1'])"
}

VERSION="$(read_config version)"
URL="$(read_config url)"
SHA256="$(read_config sha256)"
SHIM="$ROOT/vendor/shims/redlamp_libraw.h"
# Hidden, so RedlampServices, which links it in, exports none of it and dead-stripping drops
# what Redlamp doesn't call.
CXXFLAGS="-std=c++17 -O3 -w -fPIC -fvisibility=hidden -fvisibility-inlines-hidden -DUSE_ZLIB -DLIBRAW_NODLL"
STAMP_VALUE="$VERSION $SHA256 $(shasum -a 256 "$SHIM" | cut -d' ' -f1) $CXXFLAGS"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$STAMP_VALUE" && "${FORCE:-0}" != "1" ]]; then
    echo "==> LibRaw $VERSION already built ($OUTPUT)"
    exit 0
fi

mkdir -p "$CACHE" "$BUILD"
TARBALL="$CACHE/LibRaw-$VERSION.tar.gz"

if [[ ! -f "$TARBALL" ]]; then
    echo "==> Downloading LibRaw $VERSION"
    curl -sfL -o "$TARBALL" "$URL"
fi

ACTUAL_SHA="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
if [[ "$ACTUAL_SHA" != "$SHA256" ]]; then
    echo "error: LibRaw tarball SHA mismatch (expected $SHA256, got $ACTUAL_SHA)" >&2
    exit 1
fi

SRC="$CACHE/LibRaw-$VERSION"
rm -rf "$SRC"
tar -xzf "$TARBALL" -C "$CACHE"

# The authoritative object list is LIB_OBJECTS in LibRaw's own Makefile.dist.
SOURCES=()
while IFS= read -r object; do
    name="$(basename "$object" .o)"
    match="$(find "$SRC/src" -name "$name.cpp" | head -1)"
    if [[ -z "$match" ]]; then
        echo "error: no source for LibRaw object $object" >&2
        exit 1
    fi
    SOURCES+=("$match")
done < <(
    awk '/^LIB_OBJECTS=/{flag=1} flag{print} flag && !/\\$/{exit}' "$SRC/Makefile.dist" \
        | tr ' \\' '\n\n' | grep '^object/.*\.o$'
)
echo "==> Compiling ${#SOURCES[@]} LibRaw sources per slice"

JOBS="$(sysctl -n hw.ncpu)"
SLICES=(
    "macosx arm64-apple-macos26.0"
    "iphoneos arm64-apple-ios26.0"
    "iphonesimulator arm64-apple-ios26.0-simulator"
)

HEADERS="$BUILD/LibRaw-headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS/LibRaw"
cp "$SRC"/libraw/*.h "$HEADERS/LibRaw/"
cp "$SHIM" "$HEADERS/LibRaw/"
cat > "$HEADERS/LibRaw/module.modulemap" <<'EOF'
module LibRaw {
    header "libraw.h"
    header "redlamp_libraw.h"
    link "c++"
    link "z"
    export *
}
EOF

XCF_ARGS=()
for slice in "${SLICES[@]}"; do
    read -r sdk target <<<"$slice"
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    objdir="$BUILD/LibRaw-obj/$sdk"
    rm -rf "$objdir"
    mkdir -p "$objdir"
    echo "==> Building slice $sdk ($target)"
    printf '%s\n' "${SOURCES[@]}" | xargs -P "$JOBS" -I{} sh -c '
        src="$1"; objdir="$2"; target="$3"; sysroot="$4"; inc="$5"; flags="$6"
        out="$objdir/$(basename "$src" .cpp).o"
        # shellcheck disable=SC2086
        xcrun clang++ -c "$src" -o "$out" \
            -target "$target" -isysroot "$sysroot" -I"$inc" $flags
    ' _ {} "$objdir" "$target" "$sysroot" "$SRC" "$CXXFLAGS"
    xcrun libtool -static -o "$objdir/libraw.a" "$objdir"/*.o 2>/dev/null
    XCF_ARGS+=(-library "$objdir/libraw.a" -headers "$HEADERS")
done

rm -rf "$OUTPUT"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$OUTPUT" >/dev/null
echo "$STAMP_VALUE" > "$STAMP"
echo "==> Built $OUTPUT"

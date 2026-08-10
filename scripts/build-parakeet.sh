#!/bin/bash
# Builds Vendor/parakeet.xcframework — the static parakeet.cpp + ggml library
# the app links for the Nemotron streaming ASR engine.
#
# Run once before the first Xcode build, and again after bumping PARAKEET_REF.
# Requires: git, cmake (brew install cmake), Xcode command line tools.
#
# Output: Vendor/parakeet.xcframework (gitignored; universal arm64 + x86_64).
# arm64 uses Metal with the shader library embedded in the binary
# (GGML_METAL_EMBED_LIBRARY); x86_64 uses CPU + Accelerate BLAS.

set -euo pipefail

PARAKEET_REF="v0.5.0"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$REPO_ROOT/Vendor"
SRC="$VENDOR/parakeet.cpp-src"
BUILD="$VENDOR/build"
OUT="$VENDOR/parakeet.xcframework"
DEPLOYMENT_TARGET="15.0"

echo "==> parakeet.cpp $PARAKEET_REF"

if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$PARAKEET_REF" https://github.com/mudler/parakeet.cpp "$SRC"
else
    git -C "$SRC" fetch --depth 1 origin "$PARAKEET_REF"
    git -C "$SRC" checkout FETCH_HEAD
fi
git -C "$SRC" submodule update --init --depth 1 third_party/ggml

build_arch() {
    local arch="$1"; shift
    local dir="$BUILD/$arch"
    echo "==> Configuring $arch"
    cmake -S "$SRC" -B "$dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DPARAKEET_BUILD_CLI=OFF \
        -DPARAKEET_BUILD_SERVER=OFF \
        -DPARAKEET_SHARED=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        "$@"
    echo "==> Building $arch"
    cmake --build "$dir" -j "$(sysctl -n hw.ncpu)"
    echo "==> Merging static libs for $arch"
    find "$dir" -name '*.a' -print0 | xargs -0 libtool -static -o "$dir/libparakeet-combined.a"
}

rm -rf "$BUILD" "$OUT"

build_arch arm64 \
    -DPARAKEET_GGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON

build_arch x86_64 \
    -DPARAKEET_GGML_METAL=OFF \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=Apple \
    -DGGML_NATIVE=OFF

echo "==> Creating universal library"
lipo -create \
    "$BUILD/arm64/libparakeet-combined.a" \
    "$BUILD/x86_64/libparakeet-combined.a" \
    -output "$BUILD/libparakeet-universal.a"

echo "==> Assembling headers + module map"
HEADERS="$BUILD/headers"
mkdir -p "$HEADERS"
cp "$SRC/include/parakeet_capi.h" "$HEADERS/"
cat > "$HEADERS/module.modulemap" <<'EOF'
module ParakeetCAPI {
    header "parakeet_capi.h"
    export *
}
EOF

echo "==> Creating xcframework"
xcodebuild -create-xcframework \
    -library "$BUILD/libparakeet-universal.a" \
    -headers "$HEADERS" \
    -output "$OUT"

echo "==> Done: $OUT"
lipo -info "$BUILD/libparakeet-universal.a"

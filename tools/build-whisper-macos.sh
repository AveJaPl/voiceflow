#!/bin/bash
# Builds whisper.cpp as ONE static library for the macOS app, so the .app has
# no runtime dependency on Homebrew (`otool -L` used to show
# /opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib — a Mac without
# `brew install whisper-cpp` could not even launch the app).
#
# Source: the same pinned submodule the Android app uses
# (android/third_party/whisper.cpp). Output (gitignored):
#   third_party/whisper-macos/lib/libwhisper.a   all ggml backends merged
#   third_party/whisper-macos/include/*.h        whisper.h + ggml headers
# macos/project.yml points HEADER_SEARCH_PATHS / LIBRARY_SEARCH_PATHS there.
#
# Metal: GGML_METAL_EMBED_LIBRARY=ON compiles the shaders into the library, so
# no .metallib has to be copied into the bundle and `ggml_backend_load_all` is
# not needed — the Metal, BLAS and CPU backends are registered statically.
#
# Usage: tools/build-whisper-macos.sh            (incremental, ~2 min cold)
#        tools/build-whisper-macos.sh --clean
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=android/third_party/whisper.cpp
OUT=third_party/whisper-macos
BUILD=third_party/build/whisper-macos
MACOS_MIN=14.0

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
    echo "[build-whisper] submodule missing — running git submodule update --init" >&2
    git submodule update --init "$SRC"
fi
command -v cmake >/dev/null || { echo "[build-whisper] cmake missing: brew install cmake" >&2; exit 1; }

if [[ "${1:-}" == "--clean" ]]; then rm -rf "$BUILD" "$OUT"; fi
mkdir -p "$BUILD" "$OUT/lib" "$OUT/include"

echo "[build-whisper] configure ($(git -C "$SRC" describe --tags --always))"
cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_DEFAULT=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DCMAKE_C_FLAGS="-Wno-shorten-64-to-32 -Wno-macro-redefined" \
    -DCMAKE_CXX_FLAGS="-Wno-shorten-64-to-32 -Wno-macro-redefined" \
    >/dev/null

echo "[build-whisper] build"
cmake --build "$BUILD" --config Release -- -j"$(sysctl -n hw.ncpu)" | grep -E "error|warning: unused" || true

# Every static archive produced by the tree, merged into one so the app links
# a single -lwhisper and never has to know which backends exist.
ARCHIVES=$(find "$BUILD" -name '*.a' -not -path '*/CMakeFiles/*')
[[ -n "$ARCHIVES" ]] || { echo "[build-whisper] no .a produced" >&2; exit 1; }
echo "$ARCHIVES" | sed 's/^/  /'
libtool -static -o "$OUT/lib/libwhisper.a" $ARCHIVES 2>&1 | grep -v "has no symbols" || true

cp "$SRC/include/whisper.h" "$OUT/include/"
cp "$SRC"/ggml/include/ggml.h "$SRC"/ggml/include/ggml-alloc.h "$SRC"/ggml/include/ggml-backend.h \
   "$SRC"/ggml/include/ggml-metal.h "$SRC"/ggml/include/ggml-cpu.h "$SRC"/ggml/include/ggml-blas.h \
   "$SRC"/ggml/include/gguf.h "$OUT/include/"

echo "[build-whisper] $(du -h "$OUT/lib/libwhisper.a" | cut -f1) → $OUT/lib/libwhisper.a"
nm "$OUT/lib/libwhisper.a" 2>/dev/null | grep -c "ggml_backend_metal_reg" | sed 's/^/[build-whisper] metal symbols: /'

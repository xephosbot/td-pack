#!/usr/bin/env bash
set -e

TD_SOURCE_DIR=${1:-td}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}
ARCH=${3:-x86_64}

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"

# Resolve absolute paths
if [ -d "$TD_SOURCE_DIR" ]; then
  TD_SOURCE_DIR="$(cd "$TD_SOURCE_DIR" >/dev/null 2>&1 && pwd)"
else
  echo "Error: TDLib source directory \"$TD_SOURCE_DIR\" doesn't exist."
  exit 1
fi

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/linux"

if [ ! -d "$OPENSSL_INSTALL_DIR" ]; then
  echo "Error: OpenSSL install directory \"$OPENSSL_INSTALL_DIR\" doesn't exist. Run build-openssl-linux.sh first."
  exit 1
fi

if [ "$ARCH" = "arm64" ]; then
    echo "Generating TDLib auto files..."

    HOST_BUILD_DIR="build-tdlib-native-jni"
    rm -rf "$HOST_BUILD_DIR"
    mkdir "$HOST_BUILD_DIR"
    cd "$HOST_BUILD_DIR" || exit 1

    cmake "$TD_SOURCE_DIR"
    cmake --build . --target prepare_cross_compiling -j"$(nproc)" || exit 1

    cd "$ROOT_DIR" || exit 1
fi

# Pick proper compiler per-arch
if [ "$ARCH" = "arm64" ]; then
    echo "Using system ARM64 cross-compiler"
    export CC=aarch64-linux-gnu-gcc
    export CXX=aarch64-linux-gnu-g++
    export AR=aarch64-linux-gnu-ar
    export RANLIB=aarch64-linux-gnu-ranlib
    export LD=aarch64-linux-gnu-ld
    export STRIP=aarch64-linux-gnu-strip

    export ZLIB_ROOT=/usr/local/arm64
    export ZLIB_LIBRARY=/usr/local/arm64/lib/libz.a
    export ZLIB_INCLUDE_DIR=/usr/local/arm64/include

    CMAKE_TOOLCHAIN_ARGS=(
        -DCMAKE_SYSTEM_NAME=Linux
        -DCMAKE_SYSTEM_PROCESSOR=aarch64
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_CXX_COMPILER="$CXX"
    )
else
    echo "Using native x86_64 toolchain"
    unset CC CXX AR RANLIB LD ZLIB_ROOT ZLIB_LIBRARY ZLIB_INCLUDE_DIR
    export STRIP=strip

    CMAKE_TOOLCHAIN_ARGS=()
fi

OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/$ARCH"
if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
    echo "Error: OpenSSL for $ARCH not found in $OPENSSL_ARCH_DIR"
    exit 1
fi

echo "Starting TDLib Linux JNI build for $ARCH..."

BUILD_DIR="build-tdlib-jni-linux-$ARCH"
INSTALL_DIR="$ROOT_DIR/tdlib/linux-jni/$ARCH"

rm -rf "$BUILD_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$BUILD_DIR"

cd "$BUILD_DIR" || exit 1

cmake "$TD_SOURCE_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
    -DTD_ENABLE_JNI=ON \
    -DTD_ENABLE_LTO=OFF \
    "${CMAKE_TOOLCHAIN_ARGS[@]}" \
    || exit 1

echo "Building tdjson (shared) for Linux $ARCH..."
cmake --build . --target tdjson -j"$(nproc)" || exit 1

cd "$ROOT_DIR" || exit 1

mkdir -p "$INSTALL_DIR/lib"

# Copy shared library
find "$BUILD_DIR" -name "libtdjson.so*" -exec cp -v {} "$INSTALL_DIR/lib/" \;

echo "Stripping shared libraries..."
for f in "$INSTALL_DIR/lib"/*.so*; do
    [ -f "$f" ] || continue
    echo "  stripping $(basename "$f")"
    "$STRIP" --strip-unneeded "$f" 2>/dev/null || true
done

rm -rf "$BUILD_DIR"
rm -rf "$HOST_BUILD_DIR" 2>/dev/null

echo "Done! TDLib Linux JNI build stored in tdlib/linux-jni/$ARCH"
ls -lh "$INSTALL_DIR/lib/"

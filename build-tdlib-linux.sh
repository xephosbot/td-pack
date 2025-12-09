#!/usr/bin/env bash

TD_SOURCE_DIR=${1:-td}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}

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

echo "Generating TDLib auto files..."

HOST_BUILD_DIR="build-tdlib-native"
rm -rf "$HOST_BUILD_DIR"
mkdir "$HOST_BUILD_DIR"
cd "$HOST_BUILD_DIR" || exit 1

cmake "$TD_SOURCE_DIR"
cmake --build . --target prepare_cross_compiling --parallel 8 || exit 1

cd "$ROOT_DIR" || exit 1

# Remove old artifacts
rm -rf tdlib/linux

echo "Starting TDLib Linux builds..."

for ARCH in x86_64 arm64; do
    echo "  Building TDLib for $ARCH"

    OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/$ARCH"
    if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
        echo "Warning: OpenSSL for $ARCH not found in $OPENSSL_ARCH_DIR. Skipping..."
        continue
    fi

    BUILD_DIR="build-tdlib-linux-$ARCH"
    INSTALL_DIR="$ROOT_DIR/tdlib/linux/$ARCH"

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    cd "$BUILD_DIR" || exit 1

    if [ "$ARCH" == "arm64" ]; then
        echo "Enabling ARM64 cross-compilation..."

        export CC=aarch64-linux-gnu-gcc
        export CXX=aarch64-linux-gnu-g++
        export AR=aarch64-linux-gnu-ar
        export RANLIB=aarch64-linux-gnu-ranlib
        export LD=aarch64-linux-gnu-ld
        export ZLIB_ROOT=/usr/local/arm64
        export ZLIB_LIBRARY=/usr/local/arm64/lib/libz.a
        export ZLIB_INCLUDE_DIR=/usr/local/arm64/include

        CMAKE_SYSTEM_FLAGS="
            -DCMAKE_SYSTEM_NAME=Linux
            -DCMAKE_SYSTEM_PROCESSOR=aarch64
            -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc
            -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++
        "
    else
        echo "Using native x86_64 toolchain"
        unset CC CXX AR RANLIB LD
        CMAKE_SYSTEM_FLAGS=""
    fi

    cmake "$TD_SOURCE_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DTD_ENABLE_JNI=OFF \
        -DTD_ENABLE_LTO=ON \
        $CMAKE_SYSTEM_FLAGS \
        || exit 1

    echo "Building TDLib for $ARCH..."
    cmake --build . --target install || exit 1

    cd "$ROOT_DIR" || exit 1
    rm -rf "$BUILD_DIR"
done

echo "Done! TDLib Linux builds stored in tdlib/linux/"

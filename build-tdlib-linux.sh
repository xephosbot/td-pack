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
cmake --build . --target prepare_cross_compiling -j$(sysctl -n hw.ncpu) || exit 1

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
    mkdir -p "$INSTALL_DIR/lib"

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

    cmake $TD_SOURCE_DIR \
        -DCMAKE_BUILD_TYPE=Release \
        -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DTD_ENABLE_JNI=OFF \
        -DTD_ENABLE_LTO=OFF \
        $CMAKE_SYSTEM_FLAGS \
        || exit 1

    echo "Building TDLib for $ARCH..."
    cmake --build . --target tdjson_static -j4 || exit 1

    mkdir -p "$INSTALL_DIR/include/td/telegram"

    cp -v "$BUILD_DIR"/*.a "$INSTALL_DIR/lib" 2>/dev/null || true
    cp -v "$BUILD_DIR"/*/*.a "$INSTALL_DIR/lib" 2>/dev/null || true
    cp -v "$OPENSSL_ARCH_DIR"/lib/libcrypto.a "$INSTALL_DIR/lib" || exit 1
    cp -v "$OPENSSL_ARCH_DIR"/lib/libssl.a "$INSTALL_DIR/lib" || exit 1
    cp -v "$TD_SOURCE_DIR"/td/telegram/td_json_client.h "$INSTALL_DIR/include/td/telegram"
    cp -v "$TD_SOURCE_DIR"/td/telegram/td_log.h "$INSTALL_DIR/include/td/telegram"
    cp -v "$BUILD_DIR"/td/telegram/tdjson_export.h "$INSTALL_DIR/include/td/telegram"

    echo "Stripping static libraries..."
    if [ "$ARCH" == "arm64" ]; then
        STRIP_BIN=aarch64-linux-gnu-strip
    else
        STRIP_BIN=strip
    fi

    for f in "$INSTALL_DIR/lib"/*.a; do
        [ -f "$f" ] || continue
        echo "  stripping $(basename "$f")"
        $STRIP_BIN --strip-unneeded "$f" 2>/dev/null || true
    done

    cd "$ROOT_DIR" || exit 1

    echo "\n"
    echo "===== Build directory tree for $ARCH ====="
    
    # If tree exists — use it
    if command -v tree &> /dev/null; then
        tree "$BUILD_DIR"
    else
        echo "(tree not installed — using fallback output)"
        find "$BUILD_DIR" | sed -e "s|[^/]*/|- |g"
    fi
    
    echo "=========================================="
    echo "\n"
    
    #rm -rf "$BUILD_DIR"
done

echo "Done! TDLib Linux builds stored in tdlib/linux/"

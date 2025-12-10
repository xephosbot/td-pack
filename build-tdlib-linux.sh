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

OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/$ARCH"
if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
    echo "Warning: OpenSSL for $ARCH not found in $OPENSSL_ARCH_DIR. Skipping..."
    exit 1
fi

if [ "$ARCH" = "arm64" ]; then
    echo "Generating TDLib auto files..."
    
    HOST_BUILD_DIR="build-tdlib-native"
    rm -rf "$HOST_BUILD_DIR"
    mkdir "$HOST_BUILD_DIR"
    cd "$HOST_BUILD_DIR" || exit 1
    
    cmake "$TD_SOURCE_DIR"
    cmake --build . --target prepare_cross_compiling -j$(sysctl -n hw.ncpu) || exit 1

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
    
    BUILD_CFLAGS="-O3 -fPIC"
    BUILD_CXXFLAGS="-O3 -fPIC"
    LDFLAGS=""
else
    echo "Using native x86_64 toolchain"
    unset CC CXX AR RANLIB LD ZLIB_ROOT ZLIB_LIBRARY ZLIB_INCLUDE_DIR
    export STRIP=strip
    
    CMAKE_TOOLCHAIN_ARGS=()
    
    BUILD_CFLAGS="-O3 -flto -fPIC"
    BUILD_CXXFLAGS="-O3 -flto -fPIC"
    LDFLAGS="-fuse-ld=lld-18"
fi

echo "Compiler: $CC"
$CC --version | head -n1

# Remove old artifacts
rm -rf tdlib/linux

echo "Starting TDLib Linux build for $ARCH..."

BUILD_DIR="build-tdlib-linux-$ARCH"
INSTALL_DIR="$ROOT_DIR/tdlib/linux/$ARCH"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$BUILD_DIR" || exit 1

cmake $TD_SOURCE_DIR \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
  -DTD_ENABLE_JNI=OFF \
  -DTD_ENABLE_LTO=OFF \
  $CMAKE_SYSTEM_FLAGS \
  || exit 1

echo "Building TDLib for $ARCH..."
cmake --build . --target tdjson_static -j$(sysctl -n hw.ncpu) || exit 1

cd "$ROOT_DIR" || exit 1

mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/include"

# Copy TDLib libraries
find "$BUILD_DIR" -name "*.a" -exec cp -v {} "$INSTALL_DIR/lib/" \;

# Copy OpenSSL static libraries
cp -v "$OPENSSL_ARCH_DIR"/lib/libcrypto.a "$INSTALL_DIR/lib" || exit 1
cp -v "$OPENSSL_ARCH_DIR"/lib/libssl.a "$INSTALL_DIR/lib" || exit 1

# Copy headers
mkdir -p "$INSTALL_DIR/include/td/telegram"
cp -v "$BUILD_DIR"/td/telegram/tdjson_export.h "$INSTALL_DIR/include/td/telegram" 2>/dev/null || true
cp -v "$TD_SOURCE_DIR"/td/telegram/td_json_client.h "$INSTALL_DIR/include" || exit 1
cp -v "$TD_SOURCE_DIR"/td/telegram/td_log.h "$INSTALL_DIR/include" || exit 1

echo "Stripping static libraries..."
for f in "$INSTALL_DIR/lib"/*.a; do
    [ -f "$f" ] || continue
    echo "  stripping $(basename "$f")"
    "$STRIP" --strip-unneeded "$f" 2>/dev/null || true
done

rm -rf "$BUILD_DIR"
rm -rf "$HOST_BUILD_DIR"

echo "Done! TDLib Linux builds stored in tdlib/linux/"
ls -lh "$INSTALL_DIR/lib/"

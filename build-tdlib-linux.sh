#!/usr/bin/env bash

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

# Pick proper compiler per-arch
if [ "$ARCH" = "arm64" ]; then
    # inside dockcross linux-arm64
    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export RANLIB=llvm-ranlib
    export STRIP=llvm-strip
else
    # host x86_64 clang
    export CC=clang-18
    export CXX=clang++-18
    export AR=llvm-ar-18
    export RANLIB=llvm-ranlib-18
    export STRIP=llvm-strip-18
fi

echo "Generating TDLib auto files..."

HOST_BUILD_DIR="build-tdlib-native"
rm -rf "$HOST_BUILD_DIR"
mkdir "$HOST_BUILD_DIR"
cd "$HOST_BUILD_DIR" || exit 1

cmake "$TD_SOURCE_DIR" -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR"
cmake --build . --target prepare_cross_compiling -j$(sysctl -n hw.ncpu) || exit 1

cd "$ROOT_DIR" || exit 1

# Remove old artifacts
rm -rf tdlib/linux

echo "Starting TDLib Linux builds..."

echo "Building TDLib for $ARCH"

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

cmake "$TD_SOURCE_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
  -DTD_ENABLE_JNI=OFF \
  -DTD_ENABLE_LTO=ON \
  -DCMAKE_C_FLAGS="-O3 -flto -fPIC" \
  -DCMAKE_CXX_FLAGS="-O3 -flto -fPIC -stdlib=libc++" \
  -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
  -DCMAKE_AR=$AR \
  -DCMAKE_RANLIB=$RANLIB \
  || exit 1

echo "Building TDLib for $ARCH..."
cmake --build . --target tdjson_static -j$(sysctl -n hw.ncpu) || exit 1

cd "$ROOT_DIR" || exit 1

mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/include"

cp -v "$BUILD_DIR"/*.a "$BUILD_DIR"/*/*.a "$INSTALL_DIR/lib" 2>/dev/null || true
# Copy OpenSSL static libraries
cp -v "$OPENSSL_ARCH_DIR"/lib/libcrypto.a "$INSTALL_DIR/lib" || exit 1
cp -v "$OPENSSL_ARCH_DIR"/lib/libssl.a "$INSTALL_DIR/lib" || exit 1
mkdir -p "$INSTALL_DIR/include/td/telegram"
cp -v "$BUILD_DIR"/td/telegram/tdjson_export.h "$INSTALL_DIR/include/td/telegram"
cp -v "$TD_SOURCE_DIR"/td/telegram/td_json_client.h "$INSTALL_DIR/include"
cp -v "$TD_SOURCE_DIR"/td/telegram/td_log.h "$INSTALL_DIR/include"

echo "Stripping static libraries..."
for f in "$INSTALL_DIR/lib"/*.a; do
    [ -f "$f" ] || continue
    echo "  stripping $(basename "$f")"
    $STRIP --strip-unneeded "$f" 2>/dev/null || true
done

rm -rf "$BUILD_DIR"

echo "Done! TDLib Linux builds stored in tdlib/linux/"

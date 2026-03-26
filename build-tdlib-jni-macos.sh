#!/usr/bin/env bash
set -e

TD_SOURCE_DIR=${1:-td}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}
ARCH=${3:-arm64}

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"

# Resolve absolute paths
if [ -d "$TD_SOURCE_DIR" ]; then
  TD_SOURCE_DIR="$(cd "$TD_SOURCE_DIR" >/dev/null 2>&1 && pwd)"
else
  echo "Error: TDLib source directory \"$TD_SOURCE_DIR\" doesn't exist."
  exit 1
fi

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/macos"

if [ ! -d "$OPENSSL_INSTALL_DIR" ]; then
  echo "Error: OpenSSL install directory \"$OPENSSL_INSTALL_DIR\" doesn't exist. Run build-openssl-macos.sh first."
  exit 1
fi

# Check required tools
for tool in cmake gperf; do
    if ! command -v "$tool" &> /dev/null; then
        echo "$tool not found. Please install it."
        exit 1
    fi
done

OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/$ARCH"
if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
    echo "Error: OpenSSL for $ARCH not found in $OPENSSL_ARCH_DIR"
    exit 1
fi

echo "Building TDLib JNI for macOS $ARCH..."

BUILD_DIR="build-tdlib-jni-macos-$ARCH"
INSTALL_DIR="$ROOT_DIR/tdlib/macos-jni/$ARCH"

rm -rf "$BUILD_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$BUILD_DIR"

cd "$BUILD_DIR" || exit 1

# Configure TDLib with JNI enabled
cmake "$TD_SOURCE_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DTD_ENABLE_JNI=ON \
    -DTD_ENABLE_LTO=OFF \
    || exit 1

# Build tdjson shared library
echo "Building tdjson (shared) for macOS $ARCH..."
cmake --build . --target tdjson -j"$(sysctl -n hw.ncpu)" || exit 1

cd "$ROOT_DIR" || exit 1

mkdir -p "$INSTALL_DIR/lib"

# Copy shared library
find "$BUILD_DIR" -name "libtdjson*.dylib" -exec cp -v {} "$INSTALL_DIR/lib/" \;

echo "Stripping shared libraries..."
if [ -d "$INSTALL_DIR/lib" ]; then
    strip -x "$INSTALL_DIR"/lib/*.dylib 2>/dev/null || true
fi

rm -rf "$BUILD_DIR"

echo "Done. TDLib macOS JNI build stored in tdlib/macos-jni/$ARCH"
ls -lh "$INSTALL_DIR/lib"

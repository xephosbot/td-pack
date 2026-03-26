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

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/ios"

if [ ! -d "$OPENSSL_INSTALL_DIR" ]; then
  echo "Error: OpenSSL install directory \"$OPENSSL_INSTALL_DIR\" doesn't exist. Run build-openssl-ios.sh first."
  exit 1
fi

# Check required tools
for tool in cmake gperf; do
    if ! command -v "$tool" &> /dev/null; then
        echo "$tool not found. Please install it."
        exit 1
    fi
done

if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "arm64-simulator" ] && [ "$ARCH" != "x86_64-simulator" ]; then
    echo "Error: Unsupported architecture '$ARCH'. Supported: arm64, arm64-simulator, x86_64-simulator."
    exit 1
fi

# Determine the actual CPU architecture and SDK for CMake
case "$ARCH" in
    arm64)
        CMAKE_ARCH="arm64"
        CMAKE_SDK="iphoneos"
        ;;
    arm64-simulator)
        CMAKE_ARCH="arm64"
        CMAKE_SDK="iphonesimulator"
        ;;
    x86_64-simulator)
        CMAKE_ARCH="x86_64"
        CMAKE_SDK="iphonesimulator"
        ;;
esac

OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/$ARCH"
if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
    echo "Error: OpenSSL for $ARCH not found in $OPENSSL_ARCH_DIR"
    exit 1
fi

# Generate TDLib auto files natively (required for cross-compilation)
echo "Generating TDLib auto files..."
HOST_BUILD_DIR="build-tdlib-native-ios"
rm -rf "$HOST_BUILD_DIR"
mkdir "$HOST_BUILD_DIR"
cd "$HOST_BUILD_DIR" || exit 1

cmake "$TD_SOURCE_DIR"
cmake --build . --target prepare_cross_compiling -j"$(sysctl -n hw.ncpu)" || exit 1

cd "$ROOT_DIR" || exit 1

# Output directory
rm -rf "tdlib/ios/$ARCH"

echo "Building TDLib for iOS $ARCH..."

BUILD_DIR="build-tdlib-ios-$ARCH"
INSTALL_DIR="$ROOT_DIR/tdlib/ios/$ARCH"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$BUILD_DIR" || exit 1

IOS_MIN_VERSION="13.0"

# Configure TDLib for iOS cross-compilation
cmake "$TD_SOURCE_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCH" \
    -DCMAKE_OSX_SYSROOT="$CMAKE_SDK" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
    -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_ARCH_DIR/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$OPENSSL_ARCH_DIR/lib/libssl.a" \
    -DOPENSSL_INCLUDE_DIR="$OPENSSL_ARCH_DIR/include" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DTD_ENABLE_JNI=OFF \
    -DTD_ENABLE_LTO=OFF \
    || exit 1

# Build tdjson_static
echo "Building TDLib tdjson_static for iOS $ARCH..."
cmake --build . --target tdjson_static -j"$(sysctl -n hw.ncpu)" || exit 1

cd "$ROOT_DIR" || exit 1

mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/include"

# Copy TDLib static libs
cp -v "$BUILD_DIR"/*.a "$BUILD_DIR"/*/*.a "$INSTALL_DIR/lib" 2>/dev/null || true

# Copy OpenSSL .a libraries
cp -v "$OPENSSL_ARCH_DIR/lib/libcrypto.a" "$INSTALL_DIR/lib" 2>/dev/null || true
cp -v "$OPENSSL_ARCH_DIR/lib/libssl.a"    "$INSTALL_DIR/lib" 2>/dev/null || true

# Copy headers
mkdir -p "$INSTALL_DIR/include/td/telegram"
cp -v "$BUILD_DIR"/td/telegram/tdjson_export.h "$INSTALL_DIR/include/td/telegram" 2>/dev/null || true
cp -v "$TD_SOURCE_DIR"/td/telegram/td_json_client.h "$INSTALL_DIR/include"
cp -v "$TD_SOURCE_DIR"/td/telegram/td_log.h "$INSTALL_DIR/include"

echo "Stripping static libraries..."
if [ -d "$INSTALL_DIR/lib" ]; then
    strip -S "$INSTALL_DIR"/lib/*.a 2>/dev/null || true
fi

rm -rf "$BUILD_DIR"
rm -rf "$HOST_BUILD_DIR"

echo "Done. TDLib iOS build stored in tdlib/ios/$ARCH"
ls -lh "$INSTALL_DIR/lib"

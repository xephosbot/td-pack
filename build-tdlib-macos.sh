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

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR"

if [ ! -d "$OPENSSL_INSTALL_DIR" ]; then
  echo "Error: OpenSSL install directory \"$OPENSSL_INSTALL_DIR\" doesn't exist. Run build-openssl-macos.sh first."
  exit 1
fi

# Check tools
if ! command -v cmake &> /dev/null; then
    echo "cmake not found. Please install it (e.g. brew install cmake)"
    exit 1
fi
if ! command -v gperf &> /dev/null; then
    echo "gperf not found. Please install it (e.g. brew install gperf)"
    exit 1
fi
if ! command -v strip &> /dev/null; then
    echo "strip not found. Please install it (e.g. brew install strip)"
    exit 1
fi

# Clean output directory for macOS
rm -rf tdlib/macos

# Build TDLib for each architecture
for ARCH in arm64 x86_64; do
    echo "Building TDLib for $ARCH..."
    
    OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/macos/$ARCH"
    if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
        echo "Warning: OpenSSL for $ARCH not found in $OPENSSL_ARCH_DIR. Skipping..."
        continue
    fi

    BUILD_DIR="build-tdlib-macos-$ARCH"
    INSTALL_DIR="$ROOT_DIR/tdlib/macos/$ARCH"
    
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    cd "$BUILD_DIR" || exit 1
    
    # Configure
    # We use -DTD_ENABLE_JNI=OFF to skip Java bindings since user requested native C build
    cmake "$TD_SOURCE_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DTD_ENABLE_JNI=OFF \
        -DTD_ENABLE_LTO=OFF \
        || exit 1

    # Build and Install
    echo "Building for $ARCH..."
    cmake --build . --target tdjson_static -j$(sysctl -n hw.ncpu) || exit 1

    cd "$ROOT_DIR" || exit 1

    mkdir -p "$INSTALL_DIR/lib"
    mkdir -p "$INSTALL_DIR/include"

    cp -v "$BUILD_DIR"/*.a "$BUILD_DIR"/*/*.a "$INSTALL_DIR/lib" 2>/dev/null || true
    # Copy OpenSSL static libraries
    cp -v "$OPENSSL_ARCH_DIR/lib/libcrypto.a" "$INSTALL_DIR/lib" 2>/dev/null || true
    cp -v "$OPENSSL_ARCH_DIR/lib/libssl.a"    "$INSTALL_DIR/lib" 2>/dev/null || true
    mkdir -p "$INSTALL_DIR/include/td/telegram"
    cp -v "$BUILD_DIR"/td/telegram/tdjson_export.h "$INSTALL_DIR/include/td/telegram"
    cp -v "$TD_SOURCE_DIR"/td/telegram/td_json_client.h "$INSTALL_DIR/include"
    cp -v "$TD_SOURCE_DIR"/td/telegram/td_log.h "$INSTALL_DIR/include"

    echo "Stripping static libraries..."
    if [ -d "$INSTALL_DIR/lib" ]; then
        strip -S "$INSTALL_DIR"/lib/*.a 2>/dev/null || true
    fi

    rm -rf "$BUILD_DIR"
done

echo "Done. Artifacts are in tdlib/macos/"
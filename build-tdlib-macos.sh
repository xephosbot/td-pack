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
        -DTD_ENABLE_LTO=ON \
        || exit 1

    # Build and Install
    echo "Building for $ARCH..."
    cmake --build . --target install --parallel 8 || exit 1
    
    cd "$ROOT_DIR" || exit 1

    # Clean build directory to save space
    rm -rf "$BUILD_DIR"
done

echo "Done. Artifacts are in tdlib/macos/"
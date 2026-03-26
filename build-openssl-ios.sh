#!/usr/bin/env bash
set -e

OPENSSL_SOURCE_DIR=${1:-openssl}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}
ARCH=${3:-arm64}

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"

# Resolve absolute paths
if [ -d "$OPENSSL_SOURCE_DIR" ]; then
  OPENSSL_SOURCE_DIR="$(cd "$OPENSSL_SOURCE_DIR" >/dev/null 2>&1 && pwd)"
else
  echo "Error: OpenSSL source directory \"$OPENSSL_SOURCE_DIR\" doesn't exist."
  exit 1
fi

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/ios"

if [ -d "$OPENSSL_INSTALL_DIR/$ARCH" ]; then
  echo "Error: directory \"$OPENSSL_INSTALL_DIR/$ARCH\" already exists. Delete it manually to proceed."
  exit 1
fi

echo "Building OpenSSL for iOS ($ARCH)..."

cd "$OPENSSL_SOURCE_DIR" || exit 1

INSTALL_PATH="$OPENSSL_INSTALL_DIR/$ARCH"
mkdir -p "$INSTALL_PATH"

make distclean >/dev/null 2>&1 || true

# iOS SDK path
IOS_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
IOS_MIN_VERSION="13.0"

if [ "$ARCH" = "arm64" ]; then
    CONFIGURE_TARGET="ios64-cross"
else
    echo "Error: Only arm64 is supported for iOS device builds."
    exit 1
fi

echo "Using OpenSSL target: $CONFIGURE_TARGET"
echo "iOS SDK: $IOS_SDK_PATH"

export CROSS_TOP="$(xcode-select --print-path)/Platforms/iPhoneOS.platform/Developer"
export CROSS_SDK="iPhoneOS.sdk"
export CC="$(xcrun --sdk iphoneos --find clang)"

./Configure "$CONFIGURE_TARGET" \
    --prefix="$INSTALL_PATH" \
    --openssldir="$INSTALL_PATH" \
    no-shared no-tests no-dso no-engine no-comp no-hw no-async \
    -miphoneos-version-min="$IOS_MIN_VERSION" \
    >/dev/null || exit 1

make -j"$(sysctl -n hw.ncpu)" >/dev/null || exit 1
make install_sw >/dev/null || exit 1

make distclean >/dev/null 2>&1 || true

echo "Done. OpenSSL for iOS installed to $INSTALL_PATH"

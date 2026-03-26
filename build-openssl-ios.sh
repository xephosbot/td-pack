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

IOS_MIN_VERSION="13.0"

case "$ARCH" in
    arm64)
        IOS_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
        CONFIGURE_TARGET="ios64-cross"
        export CROSS_TOP="$(xcode-select --print-path)/Platforms/iPhoneOS.platform/Developer"
        export CROSS_SDK="iPhoneOS.sdk"
        export CC="$(xcrun --sdk iphoneos --find clang)"
        EXTRA_FLAGS="-miphoneos-version-min=$IOS_MIN_VERSION"
        ;;
    arm64-simulator)
        IOS_SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)
        CONFIGURE_TARGET="iossimulator-xcrun"
        export CROSS_TOP="$(xcode-select --print-path)/Platforms/iPhoneSimulator.platform/Developer"
        export CROSS_SDK="iPhoneSimulator.sdk"
        export CC="$(xcrun --sdk iphonesimulator --find clang)"
        export CFLAGS="-target arm64-apple-ios${IOS_MIN_VERSION}-simulator -isysroot $IOS_SDK_PATH"
        EXTRA_FLAGS="-mios-simulator-version-min=$IOS_MIN_VERSION"
        ;;
    x86_64-simulator)
        IOS_SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)
        CONFIGURE_TARGET="iossimulator-xcrun"
        export CROSS_TOP="$(xcode-select --print-path)/Platforms/iPhoneSimulator.platform/Developer"
        export CROSS_SDK="iPhoneSimulator.sdk"
        export CC="$(xcrun --sdk iphonesimulator --find clang)"
        export CFLAGS="-target x86_64-apple-ios${IOS_MIN_VERSION}-simulator -isysroot $IOS_SDK_PATH"
        EXTRA_FLAGS="-mios-simulator-version-min=$IOS_MIN_VERSION"
        ;;
    *)
        echo "Error: Unsupported architecture '$ARCH'. Supported: arm64, arm64-simulator, x86_64-simulator."
        exit 1
        ;;
esac

echo "Using OpenSSL target: $CONFIGURE_TARGET"
echo "iOS SDK: $IOS_SDK_PATH"

./Configure "$CONFIGURE_TARGET" \
    --prefix="$INSTALL_PATH" \
    --openssldir="$INSTALL_PATH" \
    no-shared no-tests no-dso no-engine no-comp no-hw no-async \
    $EXTRA_FLAGS \
    >/dev/null || exit 1

make -j"$(sysctl -n hw.ncpu)" >/dev/null || exit 1
make install_sw >/dev/null || exit 1

make distclean >/dev/null 2>&1 || true

echo "Done. OpenSSL for iOS installed to $INSTALL_PATH"

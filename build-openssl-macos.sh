#!/usr/bin/env bash

OPENSSL_SOURCE_DIR=${1:-openssl}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"

# Resolve absolute paths
if [ -d "$OPENSSL_SOURCE_DIR" ]; then
  OPENSSL_SOURCE_DIR="$(cd "$OPENSSL_SOURCE_DIR" >/dev/null 2>&1 && pwd)"
else
  echo "Error: OpenSSL source directory \"$OPENSSL_SOURCE_DIR\" doesn't exist."
  exit 1
fi

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/macos"

if [ -d "$OPENSSL_INSTALL_DIR" ]; then
  echo "Error: directory \"$OPENSSL_INSTALL_DIR\" already exists. Delete it manually to proceed."
  exit 1
fi

echo "Building OpenSSL from $OPENSSL_SOURCE_DIR..."

cd "$OPENSSL_SOURCE_DIR" || exit 1

for ARCH in arm64 x86_64; do
    echo "Building OpenSSL for $ARCH..."

    INSTALL_PATH="$OPENSSL_INSTALL_DIR/$ARCH"
    mkdir -p "$INSTALL_PATH"

    make distclean >/dev/null 2>&1 || true

    CONFIGURE_TARGET=""
    if [ "$ARCH" == "arm64" ]; then
        CONFIGURE_TARGET="darwin64-arm64-cc"
    else
        CONFIGURE_TARGET="darwin64-x86_64-cc"
    fi

    ./Configure "$CONFIGURE_TARGET" --prefix="$INSTALL_PATH" --openssldir="$INSTALL_PATH" no-shared >/dev/null || exit 1

    make -j$(sysctl -n hw.ncpu) >/dev/null || exit 1
    make install_sw >/dev/null || exit 1

    # Clean up for next arch
    make distclean >/dev/null || exit 1
done

echo "Done. OpenSSL installed to $OPENSSL_INSTALL_DIR"

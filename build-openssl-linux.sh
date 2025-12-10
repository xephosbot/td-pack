#!/usr/bin/env bash

OPENSSL_SOURCE_DIR=${1:-openssl}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}
ARCH=${3:-x86_64}

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"

# Resolve absolute paths
if [ -d "$OPENSSL_SOURCE_DIR" ]; then
  OPENSSL_SOURCE_DIR="$(cd "$OPENSSL_SOURCE_DIR" >/dev/null 2>&1 && pwd)"
else
  echo "Error: OpenSSL source directory \"$OPENSSL_SOURCE_DIR\" doesn't exist."
  exit 1
fi

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/linux"

if [ -d "$OPENSSL_INSTALL_DIR" ]; then
  echo "Error: directory \"$OPENSSL_INSTALL_DIR\" already exists. Delete it manually to proceed."
  exit 1
fi

echo "Building OpenSSL from $OPENSSL_SOURCE_DIR..."

cd "$OPENSSL_SOURCE_DIR" || exit 1

INSTALL_PATH="$OPENSSL_INSTALL_DIR/$ARCH"
mkdir -p "$INSTALL_PATH"

make distclean >/dev/null 2>&1 || true

if [ "$ARCH" == "arm64" ]; then
    TARGET="linux-aarch64-cross"
    CC="aarch64-unknown-linux-gnu-gcc"
    AR="aarch64-unknown-linux-gnu-ar"
    RANLIB="aarch64-unknown-linux-gnu-ranlib"
else
    TARGET="linux-x86_64"
    CC="gcc"
    AR="ar"
    RANLIB="ranlib"
fi

./Configure "$TARGET" \
    --prefix="$INSTALL_PATH" \
    --openssldir="$INSTALL_PATH" \
    no-shared no-tests -fPIC \
    CC="$CC" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    >/dev/null || exit 1

make -j"$(nproc)" >/dev/null || exit 1
make install_sw >/dev/null || exit 1

make distclean >/dev/null || exit 1

echo "Done. OpenSSL installed to $OPENSSL_INSTALL_DIR"

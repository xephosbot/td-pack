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

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/macos"

if [ -d "$OPENSSL_INSTALL_DIR/$ARCH" ]; then
  echo "Error: directory \"$OPENSSL_INSTALL_DIR/$ARCH\" already exists. Delete it manually to proceed."
  exit 1
fi

echo "Building OpenSSL for macOS ($ARCH)..."

cd "$OPENSSL_SOURCE_DIR" || exit 1

INSTALL_PATH="$OPENSSL_INSTALL_DIR/$ARCH"
mkdir -p "$INSTALL_PATH"

make distclean >/dev/null 2>&1 || true

# Choose correct OpenSSL target
if [ "$ARCH" = "arm64" ]; then
    CONFIGURE_TARGET="darwin64-arm64-cc"
else
    CONFIGURE_TARGET="darwin64-x86_64-cc"
fi

echo "Using OpenSSL target: $CONFIGURE_TARGET"

./Configure "$CONFIGURE_TARGET" \
    --prefix="$INSTALL_PATH" \
    --openssldir="$INSTALL_PATH" \
    no-shared no-tests \
    >/dev/null || exit 1

make -j"$(sysctl -n hw.ncpu)" >/dev/null || exit 1
make install_sw >/dev/null || exit 1

make distclean >/dev/null 2>&1 || true

echo "Done. OpenSSL installed to $INSTALL_PATH"

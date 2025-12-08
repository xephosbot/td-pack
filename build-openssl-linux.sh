#!/usr/bin/env bash

OPENSSL_SOURCE_DIR=${1:-openssl}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}

cd "$(dirname "$0")" || exit 1
CURRENT_DIR="$(pwd)"

# Helper to resolve absolute paths on macOS/Linux
resolve_path() {
  if [ -d "$1" ]; then
    echo "$(cd "$1" >/dev/null 2>&1 && pwd)"
  else
    echo "$1"
  fi
}

ABS_OPENSSL_SOURCE_DIR=$(resolve_path "$OPENSSL_SOURCE_DIR")
# We don't resolve install dir yet as it might not exist, but we need absolute path for Docker volume if needed.
# For simplicity, we assume relative paths are within the project for Docker mapping.

if [ "$(uname)" == "Darwin" ]; then
    echo "Detected macOS. Using Docker for Linux cross-compilation..."

    if ! command -v docker &> /dev/null; then
        echo "Error: docker is required for cross-compilation on macOS."
        echo "Please install Docker Desktop or use a Linux machine."
        exit 1
    fi

    PROJECT_ROOT="$(dirname "$CURRENT_DIR")"

    # Ensure install directory exists so it's owned by user, not root (from Docker)
    mkdir -p "$PROJECT_ROOT/$OPENSSL_INSTALL_DIR/linux"

    for ARCH in x86_64 arm64; do
        echo "=================================================="
        echo "Starting build for linux/$ARCH using Docker..."
        echo "=================================================="

        DOCKER_PLATFORM="linux/amd64"
        [ "$ARCH" == "arm64" ] && DOCKER_PLATFORM="linux/arm64"

        # Use Debian 10 (Buster) for broad compatibility (GLIBC 2.28)
        # Using -u 0 (root) to install deps, but we should be careful about file ownership.
        # We'll fix ownership at the end.

        docker run --rm --platform "$DOCKER_PLATFORM" \
            -v "$PROJECT_ROOT:/project" \
            -w "/project/source" \
            debian:10-slim \
            /bin/bash -c "
                set -e
                apt-get update -qq && apt-get install -y -qq make gcc perl >/dev/null
                ./build-openssl-linux.sh \"$OPENSSL_SOURCE_DIR\" \"$OPENSSL_INSTALL_DIR\" --inner-build
            " || exit 1

        echo "Finished build for linux/$ARCH"
    done

    # Fix ownership of the created files
    echo "Fixing file ownership..."
    if [ -n "$SUDO_USER" ]; then
        chown -R "$SUDO_USER" "$PROJECT_ROOT/$OPENSSL_INSTALL_DIR/linux"
    else
        chown -R "$(id -u):$(id -g)" "$PROJECT_ROOT/$OPENSSL_INSTALL_DIR/linux"
    fi

    echo "Done. OpenSSL installed to $PROJECT_ROOT/$OPENSSL_INSTALL_DIR/linux"
    exit 0
fi

# --- Linux Build Logic ---

# Check if this is an inner build (flag is $3, but might shift if args change)
# We just proceed.

# Resolve absolute paths again as we might be inside Docker
if [ -d "$OPENSSL_SOURCE_DIR" ]; then
  OPENSSL_SOURCE_DIR="$(cd "$OPENSSL_SOURCE_DIR" >/dev/null 2>&1 && pwd)"
else
  echo "Error: OpenSSL source directory \"$OPENSSL_SOURCE_DIR\" doesn't exist."
  exit 1
fi

# Inside Docker/Linux, we use absolute path based on current dir if not provided
# But OPENSSL_INSTALL_DIR is relative to PROJECT_ROOT usually.
# In the script logic above: OPENSSL_INSTALL_DIR=${2:-third-party/openssl}
# Inside Docker, we are in /project/source.
# $ROOT_DIR (defined below) will be /project/source.
# So $ROOT_DIR/../$OPENSSL_INSTALL_DIR works if OPENSSL_INSTALL_DIR is third-party/...

ROOT_DIR="$(pwd)"
PROJECT_ROOT="$(dirname "$ROOT_DIR")"
REAL_INSTALL_DIR="$PROJECT_ROOT/$OPENSSL_INSTALL_DIR/linux"

echo "Building OpenSSL from $OPENSSL_SOURCE_DIR..."

cd "$OPENSSL_SOURCE_DIR" || exit 1

ARCH="$(uname -m)"
INSTALL_ARCH=""
CONFIGURE_TARGET=""

if [ "$ARCH" == "x86_64" ]; then
    INSTALL_ARCH="x86_64"
    CONFIGURE_TARGET="linux-x86_64"
elif [ "$ARCH" == "aarch64" ]; then
    INSTALL_ARCH="arm64"
    CONFIGURE_TARGET="linux-aarch64"
else
    echo "Error: Unsupported architecture $ARCH"
    exit 1
fi

echo "Building OpenSSL for $ARCH (Target: $CONFIGURE_TARGET)..."

INSTALL_PATH="$REAL_INSTALL_DIR/$INSTALL_ARCH"
mkdir -p "$INSTALL_PATH"

make distclean >/dev/null 2>&1 || true

./Configure "$CONFIGURE_TARGET" --prefix="$INSTALL_PATH" --openssldir="$INSTALL_PATH" no-shared -fPIC >/dev/null || exit 1

make -j"$(nproc)" >/dev/null || exit 1
make install_sw >/dev/null || exit 1

# Clean up
make distclean >/dev/null || exit 1

echo "Installed $ARCH to $INSTALL_PATH"

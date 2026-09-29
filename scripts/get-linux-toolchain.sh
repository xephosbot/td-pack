#!/usr/bin/env bash
# =============================================================================
# scripts/get-linux-toolchain.sh
# Downloads (once) the exact GCC toolchain Kotlin/Native uses for Linux
# targets and prints its root path to stdout.
#
# Linux static libraries MUST be built with these toolchains: K/N links final
# binaries against its own bundled sysroot (glibc 2.19 for x86_64, 2.25 for
# aarch64, GCC 8.3 libstdc++). Archives built on a modern distro reference
# symbols that sysroot does not have (__isoc23_strtol, fcntl64,
# __libc_single_threaded, GCC 11+ libstdc++ helpers) and fail to link.
#
# Both toolchains are x86_64-hosted — the aarch64 one is a cross-compiler,
# so all Linux static builds can run on a plain x86_64 runner.
# =============================================================================
# Usage:
#   TOOLCHAIN_DIR="$(./scripts/get-linux-toolchain.sh <x86_64|arm64>)"
# =============================================================================

set -euo pipefail

ARCH="${1:?usage: $0 <x86_64|arm64>}"

case "$ARCH" in
  x86_64) NAME="x86_64-unknown-linux-gnu-gcc-8.3.0-glibc-2.19-kernel-4.9-2" ;;
  arm64)  NAME="aarch64-unknown-linux-gnu-gcc-8.3.0-glibc-2.25-kernel-4.9-2" ;;
  *) echo "Unknown arch: $ARCH (use x86_64 or arm64)" >&2; exit 1 ;;
esac

TRIPLE="${NAME%%-gcc-*}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLCHAINS_DIR="$PROJECT_ROOT/third_party/toolchains"
DEST="$TOOLCHAINS_DIR/$NAME"

if [[ ! -x "$DEST/bin/${TRIPLE}-gcc" ]]; then
  URL="https://download.jetbrains.com/kotlin/native/$NAME.tar.gz"
  echo "Downloading K/N toolchain: $URL" >&2
  mkdir -p "$TOOLCHAINS_DIR"
  TMP="$TOOLCHAINS_DIR/$NAME.tar.gz.part"
  curl -fL --retry 3 -o "$TMP" "$URL" >&2
  tar -xzf "$TMP" -C "$TOOLCHAINS_DIR"
  rm -f "$TMP"
  [[ -x "$DEST/bin/${TRIPLE}-gcc" ]] || { echo "Toolchain layout unexpected: no $DEST/bin/${TRIPLE}-gcc" >&2; exit 1; }
fi

echo "$DEST"

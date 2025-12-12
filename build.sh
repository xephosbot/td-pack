#!/usr/bin/env bash
set -euo pipefail

# Usage:
# ./build.sh linux x86_64
# ./build.sh linux aarch64
# ./build.sh macos arm64
# ./build.sh macos x86_64

OS=${1:-linux}
ARCH=${2:-x86_64}
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building for OS: $OS, ARCH: $ARCH"

if [ "$OS" = "linux" ]; then
  if [ "$ARCH" = "x86_64" ]; then
    conan install . -pr:b=profiles/linux_x86_64 -pr:h=profiles/linux_x86_64 --build=missing
    source build/conan/Release/generators/conanbuild.sh
    cmake --preset linux-x86_64
    cmake --build --preset build-linux-x86_64-install
  elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
    # prepare generated files using native build
    conan install . -pr:b=profiles/linux_x86_64 -pr:h=profiles/linux_x86_64 --build=missing
    source build/conan/Release/generators/conanbuild.sh
    cmake --preset linux-x86_64
    cmake --build --preset build-linux-aarch64-prepare

    # install cross deps (zlib/openssl) for aarch64 via conan
    conan install . -pr:b=profiles/linux_x86_64 -pr:h=profiles/linux_aarch64 --build=missing
    source build/conan/Release/generators/conanbuild.sh
    cmake --preset linux-aarch64
    cmake --build --preset build-linux-aarch64-install
  else
    echo "Unsupported Linux architecture: $ARCH"
    exit 1
  fi
elif [ "$OS" = "macos" ]; then
  if [ "$ARCH" = "arm64" ]; then
    # prepare generated files using native build
    conan install . -pr:b=profiles/macos_x86_64 -pr:h=profiles/macos_x86_64 --build=missing -c tools.apple:enable_bitcode=False
    source build/conan/Release/generators/conanbuild.sh
    cmake --preset macos-x86_64
    cmake --build --preset build-macos-arm64-prepare
  
    conan install . -pr:b=profiles/macos_x86_64 -pr:h=profiles/macos_arm64 --build=missing -c tools.apple:enable_bitcode=False
    source build/conan/Release/generators/conanbuild.sh
    cmake --preset macos-arm64
    cmake --build --preset build-macos-arm64-install
  elif [ "$ARCH" = "x86_64" ]; then
    conan install . -pr:b=profiles/macos_x86_64 -pr:h=profiles/macos_x86_64 --build=missing -c tools.apple:enable_bitcode=False
    source build/conan/Release/generators/conanbuild.sh
    cmake --preset macos-x86_64
    cmake --build --preset build-macos-x86_64-install
  else
    echo "Unsupported macOS architecture: $ARCH"
    exit 1
  fi
else
  echo "Unsupported OS: $OS"
  exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

# Usage:
# ./build.sh linux x86_64 [gcc|clang]
# ./build.sh linux aarch64 [gcc|clang]
# ./build.sh macos arm64
# ./build.sh macos x86_64

OS=${1:-linux}
ARCH=${2:-x86_64}
COMPILER=${3:-clang}
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building for OS: $OS, ARCH: $ARCH, COMPILER: $COMPILER"

PROFILE_SUFFIX=""
if [ "$COMPILER" = "clang" ]; then
  PROFILE_SUFFIX="_clang"
fi

if [ "$OS" = "linux" ]; then
  if [ "$ARCH" = "x86_64" ]; then
    conan install . -pr:b=profiles/linux_x86_64${PROFILE_SUFFIX} -pr:h=profiles/linux_x86_64${PROFILE_SUFFIX} --build=missing
    cmake --preset dev-release
    cmake --build --preset dev-release --target install/strip
  elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
    # prepare generated files using native build
    conan install . -pr:b=profiles/linux_x86_64${PROFILE_SUFFIX} -pr:h=profiles/linux_x86_64${PROFILE_SUFFIX} --build=missing
    cmake --preset dev-release
    cmake --build --preset dev-release --target prepare_cross_compiling

    conan install . -pr:b=profiles/linux_x86_64${PROFILE_SUFFIX} -pr:h=profiles/linux_aarch64${PROFILE_SUFFIX} --build=missing
    cmake --preset dev-release
    cmake --build --preset dev-release --target install/strip
  else
    echo "Unsupported Linux architecture: $ARCH"
    exit 1
  fi
elif [ "$OS" = "macos" ]; then
  if [ "$ARCH" = "arm64" ]; then 
    conan install . -pr:b=profiles/macos_arm64 -pr:h=profiles/macos_arm64 --build=missing
    cmake --preset dev-release
    cmake --build --preset dev-release --target install/strip
  elif [ "$ARCH" = "x86_64" ]; then
    conan install . -pr:b=profiles/macos_x86_64 -pr:h=profiles/macos_x86_64 --build=missing
    cmake --preset dev-release
    cmake --build --preset dev-release --target install/strip
  else
    echo "Unsupported macOS architecture: $ARCH"
    exit 1
  fi
else
  echo "Unsupported OS: $OS"
  exit 1
fi

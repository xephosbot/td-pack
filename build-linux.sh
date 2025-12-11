#!/usr/bin/env bash
set -euo pipefail

# Usage:
# ./build-linux.sh x86_64
# ./build-linux.sh aarch64

ARCH=${1:-x86_64}
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ensure conan dependencies
if [ "$ARCH" = "x86_64" ]; then
  conan profile detect --force --name temp_detect || true
  conan install . -pr:b=conan_profiles/linux_x86_64 -pr:h=conan_profiles/linux_x86_64 --build=missing
  cmake --preset linux-x86_64
  cmake --build --preset build-linux-x86_64-install
else
  # prepare generated files using native build
  conan install . -pr:b=conan_profiles/linux_x86_64 -pr:h=conan_profiles/linux_x86_64 --build=missing
  cmake --preset linux-x86_64
  cmake --build --preset build-linux-aarch64-prepare
  
  # install cross deps (zlib/openssl) for aarch64 via conan
  conan install . -pr:b=conan_profiles/linux_x86_64 -pr:h=conan_profiles/linux_aarch64 --build=missing
  cmake --preset linux-aarch64
  cmake --build --preset build-linux-aarch64-install
fi

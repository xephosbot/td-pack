#!/usr/bin/env bash
set -e

ANDROID_SDK_ROOT_RAW=${1:-SDK}
ANDROID_NDK_VERSION=${2:-23.2.8568313}
OPENSSL_INSTALL_DIR=${3:-third-party/openssl}
ANDROID_STL=${4:-c++_static}

# Determine repo & script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Resolve TDLib directory
TDLIB_DIR="$REPO_ROOT/td"

# Resolve SDK absolute path
ANDROID_SDK_ROOT="$(cd "$SCRIPT_DIR/$ANDROID_SDK_ROOT_RAW" && pwd)"
ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"

echo "SCRIPT_DIR = $SCRIPT_DIR"
echo "REPO_ROOT = $REPO_ROOT"
echo "TDLIB_DIR = $TDLIB_DIR"
echo "Resolved ANDROID_SDK_ROOT = $ANDROID_SDK_ROOT"
echo "Resolved ANDROID_NDK_ROOT = $ANDROID_NDK_ROOT"

# Check TDLib
if [ ! -f "$TDLIB_DIR/CMakeLists.txt" ]; then
  echo "❌ TDLib CMakeLists.txt not found at: $TDLIB_DIR"
  exit 1
fi

# Check NDK toolchain
if [ ! -f "$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" ]; then
  echo "❌ NDK toolchain not found at: $ANDROID_NDK_ROOT"
  exit 1
fi

# Load environment checks
source "$SCRIPT_DIR/check-environment.sh"

# Ensure ninja exists
if ! which ninja >/dev/null 2>&1 ; then
  echo "❌ ninja not found — install ninja-build"
  exit 1
fi

PATH="$ANDROID_SDK_ROOT/cmake/3.22.1/bin:$PATH"

echo "Building TDLib JNI (minimal)…"

rm -rf "$SCRIPT_DIR/tdlib"
mkdir -p "$SCRIPT_DIR/tdlib/libs"

for ABI in arm64-v8a armeabi-v7a x86_64 x86 ; do
  echo "----------------------------------------"
  echo "Building TDLib for ABI: $ABI"
  echo "----------------------------------------"

  BUILD_DIR="$SCRIPT_DIR/build-$ABI"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  cmake \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DOPENSSL_ROOT_DIR="$SCRIPT_DIR/$OPENSSL_INSTALL_DIR/$ABI" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -GNinja \
    -DANDROID_ABI=$ABI \
    -DANDROID_STL=$ANDROID_STL \
    -DANDROID_PLATFORM=android-16 \
    "$TDLIB_DIR"

  cmake --build . || exit 1

  OUT_DIR="$SCRIPT_DIR/tdlib/libs/$ABI"
  mkdir -p "$OUT_DIR"
  cp -p libtd*.so "$OUT_DIR/"

  # OpenSSL
  if [ -e "$SCRIPT_DIR/$OPENSSL_INSTALL_DIR/$ABI/lib/libcrypto.so" ]; then
    cp "$SCRIPT_DIR/$OPENSSL_INSTALL_DIR/$ABI/lib/libcrypto.so" "$OUT_DIR/"
    cp "$SCRIPT_DIR/$OPENSSL_INSTALL_DIR/$ABI/lib/libssl.so" "$OUT_DIR/"
  fi

  cd "$SCRIPT_DIR"
done

echo "----------------------------------------"
echo "✔ DONE: Native Android libs are at scripts/android/tdlib/libs/"
echo "----------------------------------------"

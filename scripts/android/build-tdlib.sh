#!/usr/bin/env bash
set -e

ANDROID_SDK_ROOT=${1:-SDK}
ANDROID_NDK_VERSION=${2:-23.2.8568313}
OPENSSL_INSTALL_DIR=${3:-third-party/openssl}
ANDROID_STL=${4:-c++_static}

if [ ! -d "$ANDROID_SDK_ROOT" ] ; then
  echo "Error: no Android SDK found. Run fetch-sdk.sh first."
  exit 1
fi

if [ ! -d "$OPENSSL_INSTALL_DIR" ] ; then
  echo "Error: no OpenSSL build found. Run build-openssl.sh first."
  exit 1
fi

# Determine repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Full path to TDLib
TDLIB_DIR="$REPO_ROOT/td"

echo "SCRIPT_DIR = $SCRIPT_DIR"
echo "REPO_ROOT = $REPO_ROOT"
echo "TDLIB_DIR = $TDLIB_DIR"

# Verify TDLib exists
if [ ! -f "$TDLIB_DIR/CMakeLists.txt" ]; then
  echo "Error: TDLib CMakeLists.txt not found at: $TDLIB_DIR"
  exit 1
fi

source ./check-environment.sh || exit 1

ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"
PATH=$ANDROID_SDK_ROOT/cmake/3.22.1/bin:$PATH

echo "Building TDLib JNI (no Java API)..."

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
    "$TDLIB_DIR" || exit 1

  cmake --build . --target tdjni || exit 1

  OUT_DIR="$SCRIPT_DIR/tdlib/libs/$ABI"
  mkdir -p "$OUT_DIR"
  cp -p libtd*.so "$OUT_DIR/"

  # OpenSSL libs
  if [ -e "$SCRIPT_DIR/$OPENSSL_INSTALL_DIR/$ABI/lib/libcrypto.so" ]; then
    cp "$SCRIPT_DIR/$OPENSSL_INSTALL_DIR/$ABI/lib/libcrypto.so" "$OUT_DIR/"
    cp "$SCRIPT_DIR/$OPENSSL_INSTALL_DIR/$ABI/lib/libssl.so" "$OUT_DIR/"
  fi

  cd "$SCRIPT_DIR"
done

echo "Done. Native libs are in tdlib/libs/"

#!/usr/bin/env bash
set -e

ANDROID_SDK_ROOT_RAW=${1:-SDK}
ANDROID_NDK_VERSION=${2:-23.2.8568313}
OPENSSL_INSTALL_DIR=${3:-third-party/openssl}
ANDROID_STL=${4:-c++_static}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TDLIB_DIR="$REPO_ROOT/td"

ANDROID_SDK_ROOT="$(cd "$SCRIPT_DIR/$ANDROID_SDK_ROOT_RAW" && pwd)"
ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"

echo "SCRIPT_DIR = $SCRIPT_DIR"
echo "REPO_ROOT = $REPO_ROOT"
echo "TDLIB_DIR = $TDLIB_DIR"
echo "Resolved ANDROID_SDK_ROOT = $ANDROID_SDK_ROOT"
echo "Resolved ANDROID_NDK_ROOT = $ANDROID_NDK_ROOT"

if [ ! -f "$TDLIB_DIR/CMakeLists.txt" ]; then
  echo "❌ TDLib CMakeLists.txt not found at: $TDLIB_DIR"
  exit 1
fi

source "$SCRIPT_DIR/check-environment.sh"

# -----------------------------------------------------------
# STEP 1: Generate TDLib source files (required!)
# -----------------------------------------------------------
echo "Generating TDLib auto source files…"

rm -rf "$SCRIPT_DIR/build-native"
mkdir -p "$SCRIPT_DIR/build-native"
cd "$SCRIPT_DIR/build-native"

cmake -DTD_GENERATE_SOURCE_FILES=ON "$TDLIB_DIR"
cmake --build .

cd "$SCRIPT_DIR"

# -----------------------------------------------------------
# STEP 2: Build TDLib JNI for each ABI
# -----------------------------------------------------------

rm -rf "$SCRIPT_DIR/tdlib"
mkdir -p "$SCRIPT_DIR/tdlib/libs"

PATH="$ANDROID_SDK_ROOT/cmake/3.22.1/bin:$PATH"

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

  cmake --build . --target tdjni

  OUT_DIR="$SCRIPT_DIR/tdlib/libs/$ABI"
  mkdir -p "$OUT_DIR"
  cp -p libtd*.so "$OUT_DIR/"

  if [ -e "$SCRIPT_DIR/$OPENSSL_INSTALL_DIR/$ABI/lib/libcrypto.so" ]; then
    cp "$SCRIPT_DIR/$OPENSSL_INSTALL_DIR/$ABI/lib/libcrypto.so" "$OUT_DIR/"
    cp "$SCRIPT_DIR/$OPENSSL_INSTALL_DIR/$ABI/lib/libssl.so" "$OUT_DIR/"
  fi

  cd "$SCRIPT_DIR"
done

echo "----------------------------------------"
echo "✔ DONE: Native Android libs are at scripts/android/tdlib/libs/"
echo "----------------------------------------"

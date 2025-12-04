#!/usr/bin/env bash

ANDROID_SDK_ROOT=${1:-SDK}
ANDROID_NDK_VERSION=${2:-23.2.8568313}
OPENSSL_INSTALL_DIR=${3:-third-party/openssl}
ANDROID_STL=${4:-c++_static}

source ./check-environment.sh || exit 1

if [ ! -d "$ANDROID_SDK_ROOT" ] ; then
  echo "Error: no Android SDK found. Run fetch-sdk.sh first."
  exit 1
fi

if [ ! -d "$OPENSSL_INSTALL_DIR" ] ; then
  echo "Error: no OpenSSL build found. Run build-openssl.sh first."
  exit 1
fi

ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"
PATH=$ANDROID_SDK_ROOT/cmake/3.22.1/bin:$PATH

echo "Building TDLib JNI (no Java API)..."

rm -rf tdlib
mkdir -p tdlib/libs

for ABI in arm64-v8a armeabi-v7a x86_64 x86 ; do
  echo "Building for ABI: $ABI"

  mkdir -p build-$ABI
  cd build-$ABI

  TDLIB_DIR="$(cd ../../td >/dev/null 2>&1 ; pwd)"

  cmake \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_INSTALL_DIR/$ABI" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -GNinja \
    -DANDROID_ABI=$ABI \
    -DANDROID_STL=$ANDROID_STL \
    -DANDROID_PLATFORM=android-16 \
    $TDLIB_DIR || exit 1

  cmake --build . --target tdjni || exit 1

  mkdir -p ../tdlib/libs/$ABI/
  cp -p libtd*.so ../tdlib/libs/$ABI/

  # add OpenSSL libs if present
  if [ -e "$OPENSSL_INSTALL_DIR/$ABI/lib/libcrypto.so" ]; then
    cp "$OPENSSL_INSTALL_DIR/$ABI/lib/libcrypto.so" "../tdlib/libs/$ABI/"
    cp "$OPENSSL_INSTALL_DIR/$ABI/lib/libssl.so" "../tdlib/libs/$ABI/"
  fi

  cd ..
done

echo "Done. Native libs are in tdlib/libs/"

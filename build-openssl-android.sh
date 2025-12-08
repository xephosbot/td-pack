#!/usr/bin/env bash

ANDROID_SDK_ROOT=${1:-/Users/xephosbot/Library/Android/sdk}
ANDROID_NDK_VERSION=${2:-29.0.14206865}
OPENSSL_SOURCE_DIR=${3:-openssl}
OPENSSL_INSTALL_DIR=${4:-third-party/openssl}
BUILD_SHARED_LIBS=$5

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/android"

if [ -e "$OPENSSL_INSTALL_DIR" ] ; then
  echo "Error: file or directory \"$OPENSSL_INSTALL_DIR\" already exists. Delete it manually to proceed."
  exit 1
fi

if [[ "$OS_NAME" == "win" ]] && [[ "$BUILD_SHARED_LIBS" ]] ; then
  echo "Error: OpenSSL shared libraries can't be built on Windows because of 'The command line is too long.' error during build. You can run the script in WSL instead."
  exit 1
fi

mkdir -p $OPENSSL_INSTALL_DIR || exit 1

ANDROID_SDK_ROOT="$(cd "$(dirname -- "$ANDROID_SDK_ROOT")" >/dev/null; pwd -P)/$(basename -- "$ANDROID_SDK_ROOT")"
OPENSSL_INSTALL_DIR="$(cd "$(dirname -- "$OPENSSL_INSTALL_DIR")" >/dev/null; pwd -P)/$(basename -- "$OPENSSL_INSTALL_DIR")"

cd $(dirname $0)

echo "Using OpenSSL sources from local directory..."

if [ ! -d "$OPENSSL_SOURCE_DIR" ]; then
  echo "Error: directory \"$OPENSSL_SOURCE_DIR\" doesn't exist."
  exit 1
fi
cd "$OPENSSL_SOURCE_DIR" || exit 1

export ANDROID_NDK_ROOT=$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION
export ANDROID_NDK_HOME=$ANDROID_NDK_ROOT

# Determine HOST_ARCH
if [[ "$OSTYPE" == "linux"* ]] ; then
  HOST_ARCH="linux-x86_64"
elif [[ "$OSTYPE" == "darwin"* ]] ; then
  HOST_ARCH="darwin-x86_64"
else
  echo "Error: Unsupported OS for this script."
  exit 1
fi

PATH=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_ARCH/bin:$PATH

if ! clang --help >/dev/null 2>&1 ; then
  echo "Error: failed to run clang from Android NDK."
  exit 1
fi

ANDROID_API32=16
ANDROID_API64=21
if [[ ${ANDROID_NDK_VERSION%%.*} -ge 24 ]] ; then
  ANDROID_API32=19
fi
if [[ ${ANDROID_NDK_VERSION%%.*} -ge 26 ]] ; then
  ANDROID_API32=21
fi

SHARED_BUILD_OPTION=$([ "$BUILD_SHARED_LIBS" ] && echo "shared" || echo "no-shared")

for ABI in arm64-v8a armeabi-v7a x86_64 x86 ; do
  if [[ $ABI == "x86" ]] ; then
    export ANDROID_NDK=$ANDROID_NDK_ROOT
    ./Configure android-x86 ${SHARED_BUILD_OPTION} -U__ANDROID_API__ -D__ANDROID_API__=$ANDROID_API32 || exit 1
  elif [[ $ABI == "x86_64" ]] ; then
    export ANDROID_NDK=$ANDROID_NDK_ROOT
    LDFLAGS=-Wl,-z,max-page-size=16384 ./Configure android-x86_64 ${SHARED_BUILD_OPTION} -U__ANDROID_API__ -D__ANDROID_API__=$ANDROID_API64 || exit 1
  elif [[ $ABI == "armeabi-v7a" ]] ; then
    export ANDROID_NDK=$ANDROID_NDK_ROOT
    ./Configure android-arm ${SHARED_BUILD_OPTION} -U__ANDROID_API__ -D__ANDROID_API__=$ANDROID_API32 -D__ARM_MAX_ARCH__=8 || exit 1
  elif [[ $ABI == "arm64-v8a" ]] ; then
    export ANDROID_NDK=$ANDROID_NDK_ROOT
    LDFLAGS=-Wl,-z,max-page-size=16384 ./Configure android-arm64 ${SHARED_BUILD_OPTION} -U__ANDROID_API__ -D__ANDROID_API__=$ANDROID_API64 || exit 1
  fi

  sed -i.bak 's/-O3/-O3 -ffunction-sections -fdata-sections/g' Makefile || exit 1

  make depend -s || exit 1
  make -j4 -s || exit 1

  mkdir -p $OPENSSL_INSTALL_DIR/$ABI/lib/ || exit 1
  if [ "$BUILD_SHARED_LIBS" ] ; then
    cp libcrypto.so libssl.so $OPENSSL_INSTALL_DIR/$ABI/lib/ || exit 1
  else
    cp libcrypto.a libssl.a $OPENSSL_INSTALL_DIR/$ABI/lib/ || exit 1
  fi
  cp -r include $OPENSSL_INSTALL_DIR/$ABI/ || exit 1

  make distclean || exit 1
done

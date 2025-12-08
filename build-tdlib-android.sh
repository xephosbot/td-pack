#!/usr/bin/env bash

TD_SOURCE_DIR=${1:-td}
ANDROID_SDK_ROOT=${2:-/Users/xephosbot/Library/Android/sdk}
ANDROID_NDK_VERSION=${3:-29.0.14206865}
OPENSSL_INSTALL_DIR=${4:-third-party/openssl}
ANDROID_STL=${5:-c++_static}
TDLIB_INTERFACE=${6:-JSONJava}

if [ "$ANDROID_STL" != "c++_static" ] && [ "$ANDROID_STL" != "c++_shared" ] ; then
  echo 'Error: ANDROID_STL must be either "c++_static" or "c++_shared".'
  exit 1
fi

if [ "$TDLIB_INTERFACE" != "Java" ] && [ "$TDLIB_INTERFACE" != "JSON" ] && [ "$TDLIB_INTERFACE" != "JSONJava" ] ; then
  echo 'Error: TDLIB_INTERFACE must be either "Java", "JSON", or "JSONJava".'
  exit 1
fi

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"

if [ ! -d "$ANDROID_SDK_ROOT" ] ; then
  echo "Error: directory \"$ANDROID_SDK_ROOT\" doesn't exist. Run ./fetch-sdk.sh first, or provide a valid path to Android SDK."
  exit 1
fi

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR"

if [ ! -d "$OPENSSL_INSTALL_DIR" ] ; then
  echo "Error: directory \"$OPENSSL_INSTALL_DIR\" doesn't exists. Run ./build-openssl.sh first."
  exit 1
fi

# Resolve absolute paths
if [ -d "$TD_SOURCE_DIR" ]; then
  TD_SOURCE_DIR="$(cd "$TD_SOURCE_DIR" >/dev/null 2>&1 && pwd)"
else
  echo "Error: TDLib source directory \"$TD_SOURCE_DIR\" doesn't exist."
  exit 1
fi

ANDROID_SDK_ROOT="$(cd "$(dirname -- "$ANDROID_SDK_ROOT")" >/dev/null; pwd -P)/$(basename -- "$ANDROID_SDK_ROOT")"
ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"

# Find CMake and Ninja in Android SDK
CMAKE_BIN=""
NINJA_BIN=""

check_cmake_dir() {
    local dir=$1
    if [ -d "$dir" ]; then
        if [ -x "$dir/cmake" ]; then
            CMAKE_BIN="$dir/cmake"
            PATH="$dir:$PATH"
        fi
        if [ -x "$dir/ninja" ]; then
            NINJA_BIN="$dir/ninja"
        fi
        return 0
    fi
    return 1
}

for v in 3.22.1 3.18.1 3.10.2; do
  check_cmake_dir "$ANDROID_SDK_ROOT/cmake/$v/bin" && break
done

if [ -z "$CMAKE_BIN" ]; then
   LATEST_CMAKE_DIR=$(ls -d "$ANDROID_SDK_ROOT/cmake/"*/bin 2>/dev/null | tail -n 1)
   check_cmake_dir "$LATEST_CMAKE_DIR"
fi

if [ -z "$CMAKE_BIN" ]; then
    echo "Warning: CMake not found in Android SDK. Using system CMake."
    CMAKE_BIN="cmake"
fi

if [ -z "$NINJA_BIN" ]; then
    if command -v ninja &> /dev/null; then
        NINJA_BIN=$(command -v ninja)
    else
        echo "Error: Ninja not found."
        exit 1
    fi
fi

# Determine HOST_ARCH for llvm-strip
if [[ "$OSTYPE" == "linux"* ]] ; then
  HOST_ARCH="linux-x86_64"
elif [[ "$OSTYPE" == "darwin"* ]] ; then
  HOST_ARCH="darwin-x86_64"
else
  echo "Error: Unsupported OS for this script."
  exit 1
fi

TDLIB_INTERFACE_OPTION=$([ "$TDLIB_INTERFACE" == "JSON" ] && echo "-DTD_ANDROID_JSON=ON" || [ "$TDLIB_INTERFACE" == "JSONJava" ] && echo "-DTD_ANDROID_JSON_JAVA=ON" || echo "")

# Clean output directory for Android
rm -rf tdlib/android

echo "Generating TDLib source files..."
mkdir -p build-native-$TDLIB_INTERFACE || exit 1
cd build-native-$TDLIB_INTERFACE
# We need to point to TD_SOURCE_DIR relative to here, or absolute.
cmake $TD_SOURCE_DIR $TDLIB_INTERFACE_OPTION -DTD_GENERATE_SOURCE_FILES=ON .. || exit 1
cmake --build . --parallel 8 || exit 1
cd ..

rm -rf tdlib/android

echo "Building TDLib..."
for ABI in arm64-v8a armeabi-v7a x86_64 x86 ; do
  OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/android/$ABI"
  if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
      echo "Warning: OpenSSL for $ABI not found in $OPENSSL_ARCH_DIR. Skipping..."
      continue
  fi

  INSTALL_DIR="$ROOT_DIR/tdlib/android/$ABI"
  mkdir -p "$INSTALL_DIR" || exit 1

  BUILD_DIR="build-tdlib-android-$ABI"
  mkdir -p "$BUILD_DIR" || exit 1
  cd "$BUILD_DIR"

  cmake -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -GNinja -DANDROID_ABI=$ABI \
    -DANDROID_STL=$ANDROID_STL \
    -DANDROID_PLATFORM=android-21 \
    $TDLIB_INTERFACE_OPTION ..|| exit 1

  if [ "$TDLIB_INTERFACE" == "Java" ] || [ "$TDLIB_INTERFACE" == "JSONJava" ] ; then
    echo "Building tdjni for $ABI..."
    cmake --build . --target tdjni --parallel 8 || exit 1
    cp -p libtd*.so* "$INSTALL_DIR/" || exit 1
  fi
  if [ "$TDLIB_INTERFACE" == "JSON" ] ; then
    echo "Building tdjson for $ABI..."
    cmake --build . --target tdjson --parallel 8 || exit 1
    cp -p td/libtdjson.so "$INSTALL_DIR/libtdjson.so.debug" || exit 1
    "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_ARCH/bin/llvm-strip" --strip-debug --strip-unneeded "$INSTALL_DIR/libtdjson.so.debug" -o "$INSTALL_DIR/libtdjson.so" || exit 1
    rm "$INSTALL_DIR/libtdjson.so.debug"
  fi

  # Copy shared STL if needed
  if [[ "$ANDROID_STL" == "c++_shared" ]] ; then
    if [[ "$ABI" == "arm64-v8a" ]] ; then
      FULL_ABI="aarch64-linux-android"
    elif [[ "$ABI" == "armeabi-v7a" ]] ; then
      FULL_ABI="arm-linux-androideabi"
    elif [[ "$ABI" == "x86_64" ]] ; then
      FULL_ABI="x86_64-linux-android"
    elif [[ "$ABI" == "x86" ]] ; then
      FULL_ABI="i686-linux-android"
    fi
    cp "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_ARCH/sysroot/usr/lib/$FULL_ABI/libc++_shared.so" "$INSTALL_DIR/" || exit 1
    "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_ARCH/bin/llvm-strip" "$INSTALL_DIR/libc++_shared.so" || exit 1
  fi

  # Copy OpenSSL libraries if they exist (assuming dynamic linking or distribution)
  if [ -e "$OPENSSL_ARCH_DIR/lib/libcrypto.so" ] ; then
    cp "$OPENSSL_ARCH_DIR/lib/libcrypto.so" "$OPENSSL_ARCH_DIR/lib/libssl.so" "$INSTALL_DIR/" || exit 1
    "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_ARCH/bin/llvm-strip" "$INSTALL_DIR/libcrypto.so" || exit 1
    "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_ARCH/bin/llvm-strip" "$INSTALL_DIR/libssl.so" || exit 1
  fi

  cd "$ROOT_DIR"

  # Clean build directory
  rm -rf "$BUILD_DIR"
done

rm -rf build-native-$TDLIB_INTERFACE

echo "Done. Artifacts are in tdlib/android/"

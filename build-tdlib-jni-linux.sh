#!/usr/bin/env bash
set -e

TD_SOURCE_DIR=${1:-td}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}
ARCH=${3:-x86_64}

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"

# Resolve absolute paths
if [ -d "$TD_SOURCE_DIR" ]; then
  TD_SOURCE_DIR="$(cd "$TD_SOURCE_DIR" >/dev/null 2>&1 && pwd)"
else
  echo "Error: TDLib source directory \"$TD_SOURCE_DIR\" doesn't exist."
  exit 1
fi

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/linux"

if [ ! -d "$OPENSSL_INSTALL_DIR" ]; then
  echo "Error: OpenSSL install directory \"$OPENSSL_INSTALL_DIR\" doesn't exist. Run build-openssl-linux.sh first."
  exit 1
fi

if [ "$ARCH" = "arm64" ]; then
    echo "Generating TDLib auto files..."

    HOST_BUILD_DIR="build-tdlib-native-jni"
    rm -rf "$HOST_BUILD_DIR"
    mkdir "$HOST_BUILD_DIR"
    cd "$HOST_BUILD_DIR" || exit 1

    cmake "$TD_SOURCE_DIR"
    cmake --build . --target prepare_cross_compiling -j"$(nproc)" || exit 1

    cd "$ROOT_DIR" || exit 1
fi

# Detect JAVA_HOME for JNI headers (arch-independent)
if [ -z "$JAVA_HOME" ]; then
    if command -v javac &> /dev/null; then
        JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(which javac)")")")
    fi
fi
if [ -z "$JAVA_HOME" ] || [ ! -d "$JAVA_HOME/include" ]; then
    echo "Error: Could not find JAVA_HOME with JNI headers. Install a JDK or set JAVA_HOME."
    exit 1
fi
echo "Using JAVA_HOME=$JAVA_HOME for JNI headers"

# Pick proper compiler per-arch
if [ "$ARCH" = "arm64" ]; then
    echo "Using system ARM64 cross-compiler"
    export CC=aarch64-linux-gnu-gcc
    export CXX=aarch64-linux-gnu-g++
    export AR=aarch64-linux-gnu-ar
    export RANLIB=aarch64-linux-gnu-ranlib
    export LD=aarch64-linux-gnu-ld

    export ZLIB_ROOT=/usr/local/arm64
    export ZLIB_LIBRARY=/usr/local/arm64/lib/libz.a
    export ZLIB_INCLUDE_DIR=/usr/local/arm64/include

    CMAKE_TOOLCHAIN_ARGS=(
        -DCMAKE_SYSTEM_NAME=Linux
        -DCMAKE_SYSTEM_PROCESSOR=aarch64
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_CXX_COMPILER="$CXX"
        # Pre-set JNI variables to avoid find_package(JNI) finding the host x86_64 libjvm.so.
        # JNI headers are architecture-independent, so we use the host JDK headers.
        # JAVA_JVM_LIBRARY is intentionally left empty: libtdjsonjava.so is loaded by the JVM
        # at runtime, so it does not need to link against libjvm.so at build time.
        -DJNI_FOUND=TRUE
        -DJAVA_INCLUDE_PATH="$JAVA_HOME/include"
        -DJAVA_INCLUDE_PATH2="$JAVA_HOME/include/linux"
        -DJAVA_JVM_LIBRARY=""
    )
else
    echo "Using native x86_64 toolchain"
    unset CC CXX AR RANLIB LD ZLIB_ROOT ZLIB_LIBRARY ZLIB_INCLUDE_DIR

    # Force CMake cross-compiling mode so the root CMakeLists.txt enters the
    # if (CMAKE_CROSSCOMPILING) branch that builds the tdjni target.
    CMAKE_TOOLCHAIN_ARGS=(
        -DCMAKE_SYSTEM_NAME=Linux
        -DCMAKE_SYSTEM_PROCESSOR=x86_64
        # Pre-set JNI variables to prevent find_package(JNI) from linking libjvm.so.
        # JAVA_JVM_LIBRARY is intentionally left empty: libtdjsonjava.so is loaded by
        # the JVM at runtime and does not need to link against libjvm.so at build time.
        -DJNI_FOUND=TRUE
        -DJAVA_INCLUDE_PATH="$JAVA_HOME/include"
        -DJAVA_INCLUDE_PATH2="$JAVA_HOME/include/linux"
        -DJAVA_JVM_LIBRARY=""
    )
fi

OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/$ARCH"
if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
    echo "Error: OpenSSL for $ARCH not found in $OPENSSL_ARCH_DIR"
    exit 1
fi

echo "Starting TDLib Linux JNI build (libtdjsonjava) for $ARCH..."

BUILD_DIR="build-tdlib-jni-linux-$ARCH"
INSTALL_DIR="$ROOT_DIR/tdlib/linux-jni/$ARCH"

rm -rf "$BUILD_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$BUILD_DIR"

# Apply package name patch; revert it once the build finishes (or on error).
git -C "$ROOT_DIR" apply patches/custom-package-name.patch || exit 1
revert_patch() { git -C "$ROOT_DIR" checkout -- CMakeLists.txt; }
trap revert_patch EXIT

cd "$BUILD_DIR" || exit 1

# Build against the root CMakeLists.txt which contains the tdjni target and
# TD_ANDROID_JSON_JAVA logic.  This produces libtdjsonjava.so with JNI_OnLoad
# and RegisterNatives bound to io.xbot.tdlib.JsonClient.
cmake "$ROOT_DIR" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
    -DTD_ANDROID_JSON_JAVA=ON \
    "${CMAKE_TOOLCHAIN_ARGS[@]}" \
    || exit 1

echo "Building tdjni (libtdjsonjava) for Linux $ARCH..."
cmake --build . --target tdjni -j"$(nproc)" || exit 1

cd "$ROOT_DIR" || exit 1

mkdir -p "$INSTALL_DIR/lib"

# Copy shared library (stripping is done by the CMakeLists.txt POST_BUILD step).
cp -av "$BUILD_DIR"/libtdjsonjava.so* "$INSTALL_DIR/lib/"

rm -rf "$BUILD_DIR"
rm -rf "$HOST_BUILD_DIR" 2>/dev/null

echo "Done! TDLib Linux JNI build (libtdjsonjava) stored in tdlib/linux-jni/$ARCH"
ls -lh "$INSTALL_DIR/lib/"

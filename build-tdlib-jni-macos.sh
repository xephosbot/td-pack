#!/usr/bin/env bash
set -e

TD_SOURCE_DIR=${1:-td}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}
ARCH=${3:-arm64}

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"

# Resolve absolute paths
if [ -d "$TD_SOURCE_DIR" ]; then
  TD_SOURCE_DIR="$(cd "$TD_SOURCE_DIR" >/dev/null 2>&1 && pwd)"
else
  echo "Error: TDLib source directory \"$TD_SOURCE_DIR\" doesn't exist."
  exit 1
fi

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/macos"

if [ ! -d "$OPENSSL_INSTALL_DIR" ]; then
  echo "Error: OpenSSL install directory \"$OPENSSL_INSTALL_DIR\" doesn't exist. Run build-openssl-macos.sh first."
  exit 1
fi

# Check required tools
for tool in cmake gperf; do
    if ! command -v "$tool" &> /dev/null; then
        echo "$tool not found. Please install it."
        exit 1
    fi
done

# Detect JAVA_HOME for JNI headers (arch-independent)
if [ -z "$JAVA_HOME" ]; then
    if command -v javac &> /dev/null; then
        JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(which javac)")")")
    fi
    if [ -z "$JAVA_HOME" ]; then
        # Try the macOS-specific /usr/libexec/java_home helper
        JAVA_HOME=$(/usr/libexec/java_home 2>/dev/null || true)
    fi
fi
if [ -z "$JAVA_HOME" ] || [ ! -d "$JAVA_HOME/include" ]; then
    echo "Error: Could not find JAVA_HOME with JNI headers. Install a JDK or set JAVA_HOME."
    exit 1
fi
echo "Using JAVA_HOME=$JAVA_HOME for JNI headers"

# Find a strip tool that supports GNU-style --strip-debug / --strip-unneeded flags
# (required by the CMakeLists.txt POST_BUILD strip step).
CMAKE_STRIP_ARG=""
for candidate in llvm-strip "$(brew --prefix llvm 2>/dev/null)/bin/llvm-strip"; do
    if command -v "$candidate" &>/dev/null; then
        CMAKE_STRIP_ARG="-DCMAKE_STRIP=$candidate"
        echo "Using strip tool: $candidate"
        break
    fi
done

OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/$ARCH"
if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
    echo "Error: OpenSSL for $ARCH not found in $OPENSSL_ARCH_DIR"
    exit 1
fi

echo "Building TDLib JNI (libtdjsonjava) for macOS $ARCH..."

BUILD_DIR="build-tdlib-jni-macos-$ARCH"
INSTALL_DIR="$ROOT_DIR/tdlib/macos-jni/$ARCH"

rm -rf "$BUILD_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$BUILD_DIR"

# Apply patches; revert them once the build finishes (or on error).
git -C "$ROOT_DIR" apply patches/custom-package-name.patch || exit 1
git -C "$ROOT_DIR/td" apply "$ROOT_DIR/patches/native-bridge-jni.patch" || exit 1
revert_patch() {
  git -C "$ROOT_DIR" checkout -- CMakeLists.txt
  git -C "$ROOT_DIR/td" checkout -- example/java/td_jni.cpp
}
trap revert_patch EXIT

cd "$BUILD_DIR" || exit 1

# Map ARCH to the CMake system processor name
case "$ARCH" in
    arm64)   CMAKE_PROCESSOR=arm64 ;;
    x86_64)  CMAKE_PROCESSOR=x86_64 ;;
    *)
        echo "Error: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Build against the root CMakeLists.txt which contains the tdjni target and
# TD_ANDROID_JSON_JAVA logic.  Force CMAKE_SYSTEM_NAME=Darwin so CMake enters
# the if (CMAKE_CROSSCOMPILING) branch that builds libtdjsonjava.
# Pre-set JNI variables to prevent find_package(JNI) from auto-linking libjvm.
# JAVA_JVM_LIBRARY is intentionally empty: libtdjsonjava.dylib is loaded by the
# JVM at runtime and does not need to link against libjvm.dylib at build time.
cmake "$ROOT_DIR" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_SYSTEM_NAME=Darwin \
    -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_PROCESSOR" \
    -DTD_ANDROID_JSON_JAVA=ON \
    -DJNI_FOUND=TRUE \
    -DJAVA_INCLUDE_PATH="$JAVA_HOME/include" \
    -DJAVA_INCLUDE_PATH2="$JAVA_HOME/include/darwin" \
    -DJAVA_JVM_LIBRARY="" \
    ${CMAKE_STRIP_ARG:+"$CMAKE_STRIP_ARG"} \
    || exit 1

# Build tdjni target which produces libtdjsonjava.dylib
echo "Building tdjni (libtdjsonjava) for macOS $ARCH..."
cmake --build . --target tdjni -j"$(sysctl -n hw.ncpu)" || exit 1

cd "$ROOT_DIR" || exit 1

mkdir -p "$INSTALL_DIR/lib"

# Copy shared library (stripping is done by the CMakeLists.txt POST_BUILD step).
cp -av "$BUILD_DIR"/libtdjsonjava*.dylib "$INSTALL_DIR/lib/"

rm -rf "$BUILD_DIR"

echo "Done. TDLib macOS JNI build (libtdjsonjava) stored in tdlib/macos-jni/$ARCH"
ls -lh "$INSTALL_DIR/lib"

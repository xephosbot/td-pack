#!/usr/bin/env bash
set -e

TD_SOURCE_DIR=${1:-td}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}
ARCH=${3:-x86_64}
ENABLE_JNI=false
if [ "${4}" = "--jni" ]; then
  ENABLE_JNI=true
fi

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

# ── Generate source files natively (arm64 cross-compile and JNI both need it) ──
NATIVE_BUILD_DIR=""
if [ "$ARCH" = "arm64" ] || [ "$ENABLE_JNI" = true ]; then
    echo "Generating TDLib auto files..."
    NATIVE_BUILD_DIR="build-tdlib-native"
    rm -rf "$NATIVE_BUILD_DIR"
    mkdir "$NATIVE_BUILD_DIR"
    cd "$NATIVE_BUILD_DIR" || exit 1

    cmake "$TD_SOURCE_DIR"
    cmake --build . --target prepare_cross_compiling -j"$(nproc)" || exit 1

    cd "$ROOT_DIR" || exit 1
fi

# ── JNI-specific setup ─────────────────────────────────────
if [ "$ENABLE_JNI" = true ]; then
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
fi

# ── Pick proper compiler per-arch ──────────────────────────
if [ "$ARCH" = "arm64" ]; then
    echo "Using system ARM64 cross-compiler"
    export CC=aarch64-linux-gnu-gcc
    export CXX=aarch64-linux-gnu-g++
    export AR=aarch64-linux-gnu-ar
    export RANLIB=aarch64-linux-gnu-ranlib
    export LD=aarch64-linux-gnu-ld
    export STRIP=aarch64-linux-gnu-strip

    export ZLIB_ROOT=/usr/local/arm64
    export ZLIB_LIBRARY=/usr/local/arm64/lib/libz.a
    export ZLIB_INCLUDE_DIR=/usr/local/arm64/include

    CMAKE_TOOLCHAIN_ARGS=(
        -DCMAKE_SYSTEM_NAME=Linux
        -DCMAKE_SYSTEM_PROCESSOR=aarch64
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_CXX_COMPILER="$CXX"
    )
else
    echo "Using native x86_64 toolchain"
    unset CC CXX AR RANLIB LD ZLIB_ROOT ZLIB_LIBRARY ZLIB_INCLUDE_DIR
    export STRIP=strip

    if [ "$ENABLE_JNI" = true ]; then
      # For x86_64 JNI: force cross-compiling mode so the root CMakeLists.txt
      # enters the if(CMAKE_CROSSCOMPILING) branch that builds the tdjni target.
      CMAKE_TOOLCHAIN_ARGS=(
          -DCMAKE_SYSTEM_NAME=Linux
          -DCMAKE_SYSTEM_PROCESSOR=x86_64
      )
    else
      CMAKE_TOOLCHAIN_ARGS=()
    fi
fi

# Add JNI-specific CMake flags
if [ "$ENABLE_JNI" = true ]; then
  CMAKE_TOOLCHAIN_ARGS+=(
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

if [ "$ENABLE_JNI" = true ]; then
  OUTPUT_SUBDIR="linux-jni"
  BUILD_DIR="build-tdlib-jni-linux-$ARCH"
else
  OUTPUT_SUBDIR="linux"
  BUILD_DIR="build-tdlib-linux-$ARCH"
fi

INSTALL_DIR="$ROOT_DIR/tdlib/$OUTPUT_SUBDIR/$ARCH"

rm -rf "$INSTALL_DIR"
echo "Starting TDLib Linux build for $ARCH (JNI: $ENABLE_JNI)..."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Apply JNI patches ──────────────────────────────────────
if [ "$ENABLE_JNI" = true ]; then
  git -C "$ROOT_DIR/td" apply "$ROOT_DIR/patches/native-bridge-jni.patch" || exit 1
  revert_patch() {
    git -C "$ROOT_DIR/td" checkout -- example/java/td_jni.cpp
  }
  trap revert_patch EXIT
fi

cd "$BUILD_DIR" || exit 1

# ── Configure & Build ──────────────────────────────────────
if [ "$ENABLE_JNI" = true ]; then
  cmake "$ROOT_DIR" \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
      -DTD_ANDROID_JSON_JAVA=ON \
      -DTD_JNI_PACKAGE_NAME="io/xbot/tdlib" \
      "${CMAKE_TOOLCHAIN_ARGS[@]}" \
      || exit 1

  echo "Building tdjni (libtdjsonjava) for Linux $ARCH..."
  cmake --build . --target tdjni -j"$(nproc)" || exit 1
else
  cmake "$TD_SOURCE_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
      -DTD_ENABLE_JNI=OFF \
      -DTD_ENABLE_LTO=OFF \
      "${CMAKE_TOOLCHAIN_ARGS[@]}" \
      || exit 1

  echo "Building tdjson_static for Linux $ARCH..."
  cmake --build . --target tdjson_static -j"$(nproc)" || exit 1
fi

cd "$ROOT_DIR" || exit 1

# ── Collect artifacts ──────────────────────────────────────
mkdir -p "$INSTALL_DIR/lib"

if [ "$ENABLE_JNI" = true ]; then
  cp -av "$BUILD_DIR"/libtdjsonjava.so* "$INSTALL_DIR/lib/"
else
  mkdir -p "$INSTALL_DIR/include/td/telegram"

  find "$BUILD_DIR" -name "*.a" -exec cp -v {} "$INSTALL_DIR/lib/" \;
  cp -v "$OPENSSL_ARCH_DIR"/lib/libcrypto.a "$INSTALL_DIR/lib" || exit 1
  cp -v "$OPENSSL_ARCH_DIR"/lib/libssl.a "$INSTALL_DIR/lib" || exit 1
  cp -v "$BUILD_DIR"/td/telegram/tdjson_export.h "$INSTALL_DIR/include/td/telegram" 2>/dev/null || true
  cp -v "$TD_SOURCE_DIR"/td/telegram/td_json_client.h "$INSTALL_DIR/include" || exit 1
  cp -v "$TD_SOURCE_DIR"/td/telegram/td_log.h "$INSTALL_DIR/include" || exit 1

  echo "Stripping static libraries..."
  for f in "$INSTALL_DIR/lib"/*.a; do
      [ -f "$f" ] || continue
      echo "  stripping $(basename "$f")"
      "$STRIP" --strip-unneeded "$f" 2>/dev/null || true
  done
fi

rm -rf "$BUILD_DIR"
[ -n "$NATIVE_BUILD_DIR" ] && rm -rf "$NATIVE_BUILD_DIR"

echo "Done! TDLib Linux build stored in tdlib/$OUTPUT_SUBDIR/$ARCH"
ls -lh "$INSTALL_DIR/lib/"

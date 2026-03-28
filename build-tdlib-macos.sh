#!/usr/bin/env bash
set -e

TD_SOURCE_DIR=${1:-td}
OPENSSL_INSTALL_DIR=${2:-third-party/openssl}
ARCH=${3:-arm64}
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

OPENSSL_INSTALL_DIR="$ROOT_DIR/$OPENSSL_INSTALL_DIR/macos"

if [ ! -d "$OPENSSL_INSTALL_DIR" ]; then
  echo "Error: OpenSSL install directory \"$OPENSSL_INSTALL_DIR\" doesn't exist. Run build-openssl-macos.sh first."
  exit 1
fi

# Check required tools
REQUIRED_TOOLS="cmake gperf"
if [ "$ENABLE_JNI" = false ]; then
  REQUIRED_TOOLS="$REQUIRED_TOOLS strip"
fi
for tool in $REQUIRED_TOOLS; do
    if ! command -v "$tool" &> /dev/null; then
        echo "$tool not found. Please install it."
        exit 1
    fi
done

OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/$ARCH"
if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
    echo "Error: OpenSSL for $ARCH not found in $OPENSSL_ARCH_DIR"
    exit 1
fi

# ── JNI-specific setup ─────────────────────────────────────
if [ "$ENABLE_JNI" = true ]; then
  # Detect JAVA_HOME for JNI headers (arch-independent)
  if [ -z "$JAVA_HOME" ]; then
      if command -v javac &> /dev/null; then
          JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(which javac)")")")
      fi
      if [ -z "$JAVA_HOME" ]; then
          JAVA_HOME=$(/usr/libexec/java_home 2>/dev/null || true)
      fi
  fi
  if [ -z "$JAVA_HOME" ] || [ ! -d "$JAVA_HOME/include" ]; then
      echo "Error: Could not find JAVA_HOME with JNI headers. Install a JDK or set JAVA_HOME."
      exit 1
  fi
  echo "Using JAVA_HOME=$JAVA_HOME for JNI headers"

  OUTPUT_SUBDIR="macos-jni"
  BUILD_DIR="build-tdlib-jni-macos-$ARCH"
else
  OUTPUT_SUBDIR="macos"
  BUILD_DIR="build-tdlib-macos-$ARCH"
fi

INSTALL_DIR="$ROOT_DIR/tdlib/$OUTPUT_SUBDIR/$ARCH"

# Clean output
rm -rf "$INSTALL_DIR"

echo "Building TDLib for macOS $ARCH (JNI: $ENABLE_JNI)..."

# ── prepare_cross_compiling (JNI always needs it, static doesn't) ──
HOST_BUILD_DIR=""
if [ "$ENABLE_JNI" = true ]; then
  echo "Generating TDLib auto files..."
  HOST_BUILD_DIR="build-tdlib-native-jni"
  rm -rf "$HOST_BUILD_DIR"
  mkdir "$HOST_BUILD_DIR"
  cd "$HOST_BUILD_DIR" || exit 1

  cmake "$TD_SOURCE_DIR"
  cmake --build . --target prepare_cross_compiling -j"$(sysctl -n hw.ncpu)" || exit 1

  cd "$ROOT_DIR" || exit 1
fi

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
  # Map ARCH to CMake system processor name
  case "$ARCH" in
      arm64)   CMAKE_PROCESSOR=arm64 ;;
      x86_64)  CMAKE_PROCESSOR=x86_64 ;;
      *)
          echo "Error: Unsupported architecture: $ARCH"
          exit 1
          ;;
  esac

  cmake "$ROOT_DIR" \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
      -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
      -DCMAKE_SYSTEM_NAME=Darwin \
      -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_PROCESSOR" \
      -DTD_ANDROID_JSON_JAVA=ON \
      -DTD_JNI_PACKAGE_NAME="io/xbot/tdlib" \
      -DJNI_FOUND=TRUE \
      -DJAVA_INCLUDE_PATH="$JAVA_HOME/include" \
      -DJAVA_INCLUDE_PATH2="$JAVA_HOME/include/darwin" \
      -DJAVA_JVM_LIBRARY="" \
      || exit 1

  echo "Building tdjni (libtdjsonjava) for macOS $ARCH..."
  cmake --build . --target tdjni -j"$(sysctl -n hw.ncpu)" || exit 1
else
  cmake "$TD_SOURCE_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
      -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
      -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
      -DTD_ENABLE_JNI=OFF \
      -DTD_ENABLE_LTO=OFF \
      || exit 1

  echo "Building tdjson_static for macOS $ARCH..."
  cmake --build . --target tdjson_static -j"$(sysctl -n hw.ncpu)" || exit 1
fi

cd "$ROOT_DIR" || exit 1

# ── Collect artifacts ──────────────────────────────────────
mkdir -p "$INSTALL_DIR/lib"

if [ "$ENABLE_JNI" = true ]; then
  cp -av "$BUILD_DIR"/libtdjsonjava*.dylib "$INSTALL_DIR/lib/"
else
  mkdir -p "$INSTALL_DIR/include/td/telegram"

  cp -v "$BUILD_DIR"/*.a "$BUILD_DIR"/*/*.a "$INSTALL_DIR/lib" 2>/dev/null || true
  cp -v "$OPENSSL_ARCH_DIR/lib/libcrypto.a" "$INSTALL_DIR/lib" 2>/dev/null || true
  cp -v "$OPENSSL_ARCH_DIR/lib/libssl.a"    "$INSTALL_DIR/lib" 2>/dev/null || true
  cp -v "$BUILD_DIR"/td/telegram/tdjson_export.h "$INSTALL_DIR/include/td/telegram" 2>/dev/null || true
  cp -v "$TD_SOURCE_DIR"/td/telegram/td_json_client.h "$INSTALL_DIR/include"
  cp -v "$TD_SOURCE_DIR"/td/telegram/td_log.h "$INSTALL_DIR/include"

  echo "Stripping static libraries..."
  if [ -d "$INSTALL_DIR/lib" ]; then
      strip -S "$INSTALL_DIR"/lib/*.a 2>/dev/null || true
  fi
fi

rm -rf "$BUILD_DIR"
[ -n "$HOST_BUILD_DIR" ] && rm -rf "$HOST_BUILD_DIR"

echo "Done. TDLib macOS build stored in tdlib/$OUTPUT_SUBDIR/$ARCH"
ls -lh "$INSTALL_DIR/lib"

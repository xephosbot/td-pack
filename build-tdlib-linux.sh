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

if command -v nproc &> /dev/null; then
    NPROC=$(nproc)
elif command -v sysctl &> /dev/null; then
    NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
else
    NPROC=4
fi

# Pick proper compiler per-arch
if [ "$ARCH" = "arm64" ]; then
    if [ -n "$CROSS_ROOT" ]; then
        echo "Detected dockcross environment for ARM64 with Clang 14"
        
        export CC=clang-14
        export CXX=clang++-14
        export AR=llvm-ar-14
        export RANLIB=llvm-ranlib-14
        export STRIP=llvm-strip-14
        
        export CFLAGS="--target=aarch64-unknown-linux-gnu --sysroot=$CROSS_ROOT"
        export CXXFLAGS="--target=aarch64-unknown-linux-gnu --sysroot=$CROSS_ROOT"
        
        CMAKE_TOOLCHAIN_ARGS=(
            -DCMAKE_SYSTEM_NAME=Linux
            -DCMAKE_SYSTEM_PROCESSOR=aarch64
            -DCMAKE_C_COMPILER="$CC"
            -DCMAKE_CXX_COMPILER="$CXX"
            -DCMAKE_C_COMPILER_TARGET=aarch64-unknown-linux-gnu
            -DCMAKE_CXX_COMPILER_TARGET=aarch64-unknown-linux-gnu
            -DCMAKE_SYSROOT="$CROSS_ROOT"
        )
        
        BUILD_CFLAGS="-O3 -fPIC $CFLAGS"
        BUILD_CXXFLAGS="-O3 -fPIC -stdlib=libc++ $CXXFLAGS"
        LDFLAGS="-fuse-ld=lld-18"
    else
        echo "Using system ARM64 cross-compiler"
        export CC=aarch64-linux-gnu-gcc
        export CXX=aarch64-linux-gnu-g++
        export AR=aarch64-linux-gnu-ar
        export RANLIB=aarch64-linux-gnu-ranlib
        export STRIP=aarch64-linux-gnu-strip
        
        CMAKE_TOOLCHAIN_ARGS=(
            -DCMAKE_SYSTEM_NAME=Linux
            -DCMAKE_SYSTEM_PROCESSOR=aarch64
            -DCMAKE_C_COMPILER="$CC"
            -DCMAKE_CXX_COMPILER="$CXX"
        )
        
        BUILD_CFLAGS="-O3 -fPIC"
        BUILD_CXXFLAGS="-O3 -fPIC"
        LDFLAGS=""
    fi
else
    echo "Using native x86_64 Clang 18"
    export CC=clang-18
    export CXX=clang++-18
    export AR=llvm-ar-18
    export RANLIB=llvm-ranlib-18
    export STRIP=llvm-strip-18
    
    CMAKE_TOOLCHAIN_ARGS=()
    
    BUILD_CFLAGS="-O3 -flto -fPIC"
    BUILD_CXXFLAGS="-O3 -flto -fPIC -stdlib=libc++"
    LDFLAGS="-fuse-ld=lld-18"
fi

echo "Compiler: $CC"
$CC --version | head -n1

OPENSSL_ARCH_DIR="$OPENSSL_INSTALL_DIR/$ARCH"
if [ ! -d "$OPENSSL_ARCH_DIR" ]; then
    echo "Warning: OpenSSL for $ARCH not found in $OPENSSL_ARCH_DIR. Skipping..."
    continue
fi

echo "Generating TDLib auto files..."
HOST_BUILD_DIR="build-tdlib-native"
rm -rf "$HOST_BUILD_DIR"
mkdir "$HOST_BUILD_DIR"
cd "$HOST_BUILD_DIR" || exit 1

cmake "$TD_SOURCE_DIR" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
    "${CMAKE_TOOLCHAIN_ARGS[@]}" \
    || exit 1
cmake --build . --target prepare_cross_compiling -j"$NPROC" || exit 1

cd "$ROOT_DIR" || exit 1

# Remove old artifacts
rm -rf tdlib/linux

echo "Starting TDLib Linux build for $ARCH..."

BUILD_DIR="build-tdlib-linux-$ARCH"
INSTALL_DIR="$ROOT_DIR/tdlib/linux/$ARCH"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$BUILD_DIR" || exit 1

cmake "$TD_SOURCE_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENSSL_ROOT_DIR="$OPENSSL_ARCH_DIR" \
  -DTD_ENABLE_JNI=OFF \
  -DTD_ENABLE_LTO=ON \
  -DCMAKE_C_FLAGS="$BUILD_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$BUILD_CXXFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
  -DCMAKE_AR="$AR" \
  -DCMAKE_RANLIB="$RANLIB" \
  || exit 1

echo "Building TDLib for $ARCH..."
cmake --build . --target tdjson_static -j"$NPROC" || exit 1

cd "$ROOT_DIR" || exit 1

mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/include"

# Copy TDLib libraries
find "$BUILD_DIR" -name "*.a" -exec cp -v {} "$INSTALL_DIR/lib/" \;

# Copy OpenSSL static libraries
cp -v "$OPENSSL_ARCH_DIR"/lib/libcrypto.a "$INSTALL_DIR/lib" || exit 1
cp -v "$OPENSSL_ARCH_DIR"/lib/libssl.a "$INSTALL_DIR/lib" || exit 1

# Copy headers
mkdir -p "$INSTALL_DIR/include/td/telegram"
cp -v "$BUILD_DIR"/td/telegram/tdjson_export.h "$INSTALL_DIR/include/td/telegram" 2>/dev/null || true
cp -v "$TD_SOURCE_DIR"/td/telegram/td_json_client.h "$INSTALL_DIR/include" || exit 1
cp -v "$TD_SOURCE_DIR"/td/telegram/td_log.h "$INSTALL_DIR/include" || exit 1

echo "Stripping static libraries..."
for f in "$INSTALL_DIR/lib"/*.a; do
    [ -f "$f" ] || continue
    echo "  stripping $(basename "$f")"
    "$STRIP" --strip-unneeded "$f" 2>/dev/null || true
done

rm -rf "$BUILD_DIR"
rm -rf "$HOST_BUILD_DIR"

echo "Done! TDLib Linux builds stored in tdlib/linux/"
ls -lh "$INSTALL_DIR/lib/"

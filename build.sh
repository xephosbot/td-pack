#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────
#  td-pack build script
#  Usage: ./build.sh <platform> <target>
#
#  Platforms: macos-arm64, macos-x86_64, linux-x86_64, linux-arm64,
#             android-arm64-v8a, android-armeabi-v7a, android-x86_64,
#             android-x86, ios-arm64, ios-arm64-simulator, ios-x86_64-simulator
#
#  Targets:  tdlib       (static libraries)
#            tdlib_jni   (JNI shared library)
# ──────────────────────────────────────────────────────────

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"

VALID_PLATFORMS=(
  macos-arm64 macos-x86_64
  linux-x86_64 linux-arm64
  android-arm64-v8a android-armeabi-v7a android-x86_64 android-x86
  ios-arm64 ios-arm64-simulator ios-x86_64-simulator
)

usage() {
  echo "Usage: $0 <platform> <target>"
  echo ""
  echo "Platforms: ${VALID_PLATFORMS[*]}"
  echo "Targets:   tdlib (static), tdlib_jni (JNI shared)"
  exit 1
}

# --- Validate arguments ---
[[ $# -lt 2 ]] && usage

PLATFORM="$1"
TARGET="$2"

# Check platform is valid
PLATFORM_VALID=false
for p in "${VALID_PLATFORMS[@]}"; do
  [[ "$p" == "$PLATFORM" ]] && PLATFORM_VALID=true && break
done
$PLATFORM_VALID || { echo "Error: unknown platform '$PLATFORM'"; usage; }

# Check target is valid
[[ "$TARGET" == "tdlib" || "$TARGET" == "tdlib_jni" ]] || {
  echo "Error: unknown target '$TARGET' (must be tdlib or tdlib_jni)"
  usage
}

# Enforce constraints
case "$PLATFORM" in
  android-*)
    [[ "$TARGET" == "tdlib_jni" ]] || {
      echo "Error: Android only supports tdlib_jni target"
      exit 1
    }
    ;;
  ios-*)
    [[ "$TARGET" == "tdlib" ]] || {
      echo "Error: iOS only supports tdlib target"
      exit 1
    }
    ;;
esac

BUILD_DIR="$PROJECT_ROOT/build/$PLATFORM-$TARGET"

echo "═══════════════════════════════════════════════════"
echo "  td-pack build: $PLATFORM / $TARGET"
echo "═══════════════════════════════════════════════════"

# --- Step 1: Initialize submodule and apply patch ---
echo ""
echo ">>> Preparing TDLib source..."
TD_DIR="$PROJECT_ROOT/td"
git -C "$PROJECT_ROOT" submodule update --init --depth=1 td

# Apply JNI patch (skip if already applied)
PATCH_FILE="$PROJECT_ROOT/patches/native-bridge-jni.patch"
if [[ -f "$PATCH_FILE" ]]; then
  cd "$TD_DIR"
  if git apply --check "$PATCH_FILE" 2>/dev/null; then
    echo "Applying JNI patch..."
    git apply "$PATCH_FILE"
  else
    echo "JNI patch already applied or not applicable, skipping."
  fi
  cd "$PROJECT_ROOT"
fi

# --- Step 2: Install Conan dependencies ---
echo ""
echo ">>> Installing Conan dependencies..."
PROFILE="$PROJECT_ROOT/profiles/$PLATFORM"

conan install "$PROJECT_ROOT" \
  --profile:host="$PROFILE" \
  --build=missing \
  --output-folder="$BUILD_DIR"

# --- Step 2.5: prepare_cross_compiling for cross-compile targets ---
# When CMAKE_CROSSCOMPILING is true, TDLib skips generating source files
# (mime_type_to_extension.cpp, TL schemas, etc.).  We need to build the
# native generators first so those files exist in the source tree.
NEEDS_PREPARE=false
case "$PLATFORM" in
  ios-*|android-*) NEEDS_PREPARE=true ;;
  macos-x86_64)    NEEDS_PREPARE=true ;;   # CI runs on arm64; x86_64 is cross-compiled
esac

if $NEEDS_PREPARE; then
  echo ""
  echo ">>> Preparing cross-compilation (building native generators)..."
  NATIVE_GEN_DIR="$PROJECT_ROOT/build/native-gen"

  # Install native (host) Conan dependencies
  conan install "$PROJECT_ROOT" \
    --profile:build=default \
    --profile:host=default \
    --build=missing \
    --output-folder="$NATIVE_GEN_DIR"

  # Configure via root CMakeLists.txt (not td directly) so that the Conan
  # OpenSSL/zlib bridge code is applied — td's generate_json needs libcrypto.
  cmake -S "$PROJECT_ROOT" -B "$NATIVE_GEN_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$NATIVE_GEN_DIR/conan_toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DTD_ANDROID_JSON=ON

  # Build only the generators (prepare_cross_compiling target)
  NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
  cmake --build "$NATIVE_GEN_DIR" --target prepare_cross_compiling --parallel "$NPROC"
fi

# --- Step 3: Configure CMake ---
echo ""
echo ">>> Configuring CMake..."

TOOLCHAIN="$BUILD_DIR/conan_toolchain.cmake"
CMAKE_ARGS=(
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW
)

if [[ "$TARGET" == "tdlib" ]]; then
  # Static library build — use root CMakeLists.txt with TD_ANDROID_JSON
  # to get the simple add_subdirectory(td) path with bridge code for
  # Conan-provided OpenSSL/zlib
  CMAKE_ARGS+=(
    -DTD_ANDROID_JSON=ON
    -DTD_ENABLE_JNI=OFF
  )
  cmake -S "$PROJECT_ROOT" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"
else
  # JNI build — use root CMakeLists.txt
  CMAKE_ARGS+=(
    -DTD_ANDROID_JSON_JAVA=ON
    -DTD_ENABLE_JNI=ON
    -DTD_JNI_PACKAGE_NAME=io/xbot/tdlib
  )

  # Set JAVA_INCLUDE_PATH for JNI headers
  if [[ -n "${JAVA_HOME:-}" ]]; then
    case "$PLATFORM" in
      macos-*|ios-*)
        CMAKE_ARGS+=(
          -DJAVA_INCLUDE_PATH="$JAVA_HOME/include"
          -DJAVA_INCLUDE_PATH2="$JAVA_HOME/include/darwin"
        )
        ;;
      *)
        CMAKE_ARGS+=(
          -DJAVA_INCLUDE_PATH="$JAVA_HOME/include"
          -DJAVA_INCLUDE_PATH2="$JAVA_HOME/include/linux"
        )
        ;;
    esac
  fi

  cmake -S "$PROJECT_ROOT" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"
fi

# --- Step 4: Build ---
echo ""
echo ">>> Building..."
NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Build only the target we need — avoids building unnecessary benchmarks
# and the shared tdjson library which can have link-order issues with LTO.
if [[ "$TARGET" == "tdlib" ]]; then
  cmake --build "$BUILD_DIR" --target tdjson_static --parallel "$NPROC"
else
  # JNI builds: cross-compile targets have a tdjni target in root CMakeLists.txt;
  # non-cross-compile builds produce tdjson (shared) from td's CMakeLists.txt.
  if $NEEDS_PREPARE; then
    cmake --build "$BUILD_DIR" --target tdjni --parallel "$NPROC"
  else
    cmake --build "$BUILD_DIR" --target tdjson --parallel "$NPROC"
  fi
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Build complete: $BUILD_DIR"
echo "═══════════════════════════════════════════════════"

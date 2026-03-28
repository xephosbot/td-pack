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
  --profile:build=default \
  --profile:host="$PROFILE" \
  --build=missing \
  --output-folder="$BUILD_DIR"

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
  # Static library build — use TDLib's own CMakeLists.txt
  CMAKE_ARGS+=(
    -DTD_ENABLE_JNI=OFF
  )
  cmake -S "$TD_DIR" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"
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
cmake --build "$BUILD_DIR" --parallel "$NPROC"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Build complete: $BUILD_DIR"
echo "═══════════════════════════════════════════════════"

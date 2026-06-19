#!/usr/bin/env bash
# =============================================================================
# build.sh — TDLib cross-platform build driver
# =============================================================================
# Usage:
#   ./build.sh <target> <platform>
#
# Targets:
#   tdlib       — static TDLib (no JNI)
#   tdlib_jni   — JNI shared library (libtdjni)
#
# Platforms:
#   macos-arm64            macos-x86_64
#   linux-x86_64           linux-arm64
#   android-arm64-v8a      android-armeabi-v7a
#   android-x86_64         android-x86
#   ios-arm64              ios-arm64-simulator
#   ios-x86_64-simulator
#
# Examples:
#   ./build.sh tdlib macos-arm64
#   ./build.sh tdlib_jni linux-x86_64
#   ./build.sh tdlib_jni android-arm64-v8a
#   ./build.sh tdlib ios-arm64
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}${BOLD}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}${BOLD}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}${BOLD}[ERROR]${NC} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; \
             echo -e "${BOLD}${CYAN}  $*${NC}"; \
             echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; }

# ── Argument validation ────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <target> <platform>"
  echo ""
  echo "Targets:   tdlib  tdlib_jni"
  echo "Platforms: macos-arm64 macos-x86_64 linux-x86_64 linux-arm64"
  echo "           android-arm64-v8a android-armeabi-v7a android-x86_64 android-x86"
  echo "           ios-arm64 ios-arm64-simulator ios-x86_64-simulator"
  exit 1
fi

TARGET="$1"
PLATFORM="$2"

case "$TARGET" in
  tdlib|tdlib_jni) ;;
  *) error "Unknown target: $TARGET. Must be 'tdlib' or 'tdlib_jni'." ;;
esac

VALID_PLATFORMS=(
  macos-arm64 macos-x86_64
  linux-x86_64 linux-arm64
  android-arm64-v8a android-armeabi-v7a android-x86_64 android-x86
  ios-arm64 ios-arm64-simulator ios-x86_64-simulator
)

platform_valid=false
for p in "${VALID_PLATFORMS[@]}"; do
  [[ "$PLATFORM" == "$p" ]] && platform_valid=true && break
done
$platform_valid || error "Unknown platform: $PLATFORM"

# ── Paths ──────────────────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
TD_DIR="$PROJECT_ROOT/td"
PATCH_FILE="$PROJECT_ROOT/patches/native-bridge-jni.patch"
NATIVE_GEN_DIR="$BUILD_DIR/native-gen"
NATIVE_GEN_DONE="$NATIVE_GEN_DIR/.done"

# ── Parallelism ────────────────────────────────────────────────────────────────
if command -v nproc &>/dev/null; then
  NPROC=$(nproc)
elif command -v sysctl &>/dev/null; then
  NPROC=$(sysctl -n hw.logicalcpu)
else
  NPROC=4
fi

# ── Release flags for the shipped STATIC libraries ─────────────────────────────
# Reproduce CMake's GCC/Clang Release defaults (-O3 -DNDEBUG) and add
# -fno-function-sections/-fno-data-sections. td puts -ffunction-sections in
# CMAKE_CXX_FLAGS; per-config flags below come later on the command line, so the
# negative wins. This collapses the per-function section-header + section-name +
# relocation metadata that dominates the archive (~50% of the uncompressed size).
# Only for static dist — JNI keeps function-sections so its linked .so/.dylib can
# --gc-sections at function granularity. Trade-off: the consumer dead-strips at
# object, not function, granularity.
STATIC_RELEASE_FLAGS="-O3 -DNDEBUG -fno-function-sections -fno-data-sections"

# ── Step 1: Init submodule ────────────────────────────────────────────────────
banner "Initialising TDLib submodule"
git -C "$PROJECT_ROOT" submodule update --init --depth=1 td
success "Submodule ready"

# ── Step 2: Apply patch (JNI targets only) ────────────────────────────────────
apply_patch() {
  banner "Applying native-bridge-jni patch"
  if [[ ! -f "$PATCH_FILE" ]]; then
    error "Patch file not found: $PATCH_FILE"
  fi

  # Check if already applied
  if git -C "$TD_DIR" apply --check --reverse "$PATCH_FILE" 2>/dev/null; then
    info "Patch already applied, skipping"
    return 0
  fi

  # Verify it can be applied cleanly
  if ! git -C "$TD_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    error "Patch does not apply cleanly to td/. Resolve conflicts manually."
  fi

  git -C "$TD_DIR" apply "$PATCH_FILE"
  success "Patch applied"
}

# ── Helper: prepare_cross_compiling (builds native code generator) ────────────
prepare_cross_compiling() {
  banner "Preparing cross-compilation code generator"

  if [[ -f "$NATIVE_GEN_DONE" ]]; then
    info "Native code generator already built (sentinel found), skipping"
    return 0
  fi

  local extra_args=()
  # On macOS, Homebrew OpenSSL is keg-only and CMake cannot find it without a
  # hint.  The native code generator itself does not link OpenSSL, but td's
  # CMakeLists.txt still requires find_package(OpenSSL) to succeed at
  # configure time.
  if [[ "$(uname)" == "Darwin" ]]; then
    if [[ -d "/opt/homebrew/opt/openssl" ]]; then
      extra_args+=("-DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl")
    elif [[ -d "/usr/local/opt/openssl" ]]; then
      extra_args+=("-DOPENSSL_ROOT_DIR=/usr/local/opt/openssl")
    fi
  fi

  mkdir -p "$NATIVE_GEN_DIR"
  cmake -S "$TD_DIR" \
        -B "$NATIVE_GEN_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DTD_ENABLE_JNI=OFF \
        -DCMAKE_INSTALL_PREFIX="$NATIVE_GEN_DIR/install" \
        "${extra_args[@]}" \
        2>&1 | sed 's/^/  /'

  cmake --build "$NATIVE_GEN_DIR" \
        --target prepare_cross_compiling \
        --config Release \
        -j"$NPROC" \
        2>&1 | sed 's/^/  /'

  touch "$NATIVE_GEN_DONE"
  success "Native code generator ready"
}

# ── Helper: strip static libraries in-place ────────────────────────────────────
# Static .a archives ship pre-link object code; ~20% of their size is the local
# symbol table, which the consumer's linker never needs.  Drop it (keeping the
# global symbols required for linking) so the published archives are smaller.
#   GNU strip  : --strip-unneeded  (keeps globals, removes locals + debug)
#   Apple strip: -x -S             (-x removes non-globals, -S removes debug)
# ranlib is re-run afterwards so the archive symbol index stays valid.
strip_static_libs() {
  local lib_dir="$1"
  shopt -s nullglob
  local libs=("$lib_dir"/*.a)
  shopt -u nullglob
  if [[ ${#libs[@]} -eq 0 ]]; then
    warn "No .a files to strip in $lib_dir"
    return 0
  fi

  banner "Stripping ${#libs[@]} static libraries"
  local before after lib
  before=$(du -sk "$lib_dir" | cut -f1)

  for lib in "${libs[@]}"; do
    if [[ "$(uname)" == "Darwin" ]]; then
      strip -x -S "$lib" 2>/dev/null && ranlib "$lib" 2>/dev/null \
        || warn "strip/ranlib failed for $(basename "$lib") — kept as-is"
    else
      strip --strip-unneeded "$lib" 2>/dev/null && ranlib "$lib" 2>/dev/null \
        || warn "strip/ranlib failed for $(basename "$lib") — kept as-is"
    fi
  done

  after=$(du -sk "$lib_dir" | cut -f1)
  success "Static libs stripped: $((before / 1024)) MB → $((after / 1024)) MB"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Platform-specific build functions
# ═══════════════════════════════════════════════════════════════════════════════

# ── macOS / Linux — Static ─────────────────────────────────────────────────────
build_desktop_static() {
  local os="$1"      # macos | linux
  local arch="$2"    # arm64 | x86_64

  local out_dir="$PROJECT_ROOT/out/${os}/${arch}"
  local build_subdir="$BUILD_DIR/${os}-static-${arch}"

  banner "Building TDLib static — ${os}/${arch}"

  local extra_args=()

  if [[ "$os" == "macos" ]]; then
    # OpenSSL is built from source per-arch (no Homebrew, no Rosetta) by
    # scripts/build-openssl-macos.sh → third_party/openssl/macos/<arch>.
    local openssl_root="$PROJECT_ROOT/third_party/openssl/macos/${arch}"
    [[ -d "$openssl_root" ]] || error "OpenSSL for macos/${arch} not found at $openssl_root.\n" \
      "Run: ./scripts/build-openssl-macos.sh ${arch}"
    extra_args+=(
      "-DOPENSSL_ROOT_DIR=${openssl_root}"
      "-DCMAKE_OSX_ARCHITECTURES=${arch}"
    )
  fi

  # Release, not MinSizeRel: with td's -ffunction-sections, -Os inlines less →
  # more per-function sections/relocations → larger AND less-compressible .a.
  mkdir -p "$build_subdir"
  cmake -S "$TD_DIR" \
        -B "$build_subdir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS_RELEASE="$STATIC_RELEASE_FLAGS" \
        -DCMAKE_CXX_FLAGS_RELEASE="$STATIC_RELEASE_FLAGS" \
        -DTD_ENABLE_JNI=OFF \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        "${extra_args[@]}" \
        2>&1 | sed 's/^/  /'

  cmake --build "$build_subdir" \
        --target tdjson_static \
        --config Release \
        -j"$NPROC" \
        2>&1 | sed 's/^/  /'

  # Manual copy of artifacts
  mkdir -p "$out_dir/lib"
  mkdir -p "$out_dir/include/td/telegram"

  # Copy all .a files from build dir (1 and 2 levels deep)
  cp -v "$build_subdir"/*.a "$out_dir/lib" 2>/dev/null || true
  cp -v "$build_subdir"/*/*.a "$out_dir/lib" 2>/dev/null || true

  # Copy OpenSSL static libraries
  if [[ "$os" == "macos" ]]; then
    cp -v "$openssl_root/lib/libcrypto.a" "$out_dir/lib" 2>/dev/null || true
    cp -v "$openssl_root/lib/libssl.a" "$out_dir/lib" 2>/dev/null || true
  else
    # Linux: copy system OpenSSL .a if available
    for d in /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/lib; do
      if [[ -f "$d/libcrypto.a" ]]; then
        cp -v "$d/libcrypto.a" "$out_dir/lib" 2>/dev/null || true
        cp -v "$d/libssl.a" "$out_dir/lib" 2>/dev/null || true
        break
      fi
    done
  fi

  # Strip local symbols/debug from all .a (incl. OpenSSL) to shrink the archive
  strip_static_libs "$out_dir/lib"

  # Copy specific headers
  cp -v "$build_subdir/td/telegram/tdjson_export.h" "$out_dir/include/td/telegram" 2>/dev/null || true
  cp -v "$TD_DIR/td/telegram/td_json_client.h" "$out_dir/include" 2>/dev/null || true
  cp -v "$TD_DIR/td/telegram/td_log.h" "$out_dir/include" 2>/dev/null || true

  success "Static build complete → $out_dir"
}

# ── macOS / Linux — JNI ───────────────────────────────────────────────────────
build_desktop_jni() {
  local os="$1"
  local arch="$2"

  local build_subdir="$BUILD_DIR/${os}-jni-${arch}"
  local out_dir="$PROJECT_ROOT/out/${os}-jni/${arch}"

  banner "Building TDLib JNI — ${os}/${arch}"

  local extra_args=()

  if [[ "$os" == "macos" ]]; then
    # OpenSSL is built from source per-arch (no Homebrew, no Rosetta) by
    # scripts/build-openssl-macos.sh → third_party/openssl/macos/<arch>.
    local openssl_root="$PROJECT_ROOT/third_party/openssl/macos/${arch}"
    [[ -d "$openssl_root" ]] || error "OpenSSL for macos/${arch} not found at $openssl_root.\n" \
      "Run: ./scripts/build-openssl-macos.sh ${arch}"
    extra_args+=(
      "-DOPENSSL_ROOT_DIR=${openssl_root}"
      "-DCMAKE_OSX_ARCHITECTURES=${arch}"
    )
  fi

  # Determine JAVA_HOME
  local java_home="${JAVA_HOME:-}"
  if [[ -z "$java_home" ]]; then
    if [[ "$os" == "macos" ]]; then
      if [[ "$arch" == "arm64" ]]; then
        java_home="/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"
      else
        java_home="/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home"
      fi
    fi
  fi

  if [[ -n "$java_home" ]]; then
    [[ -d "$java_home" ]] || error "JAVA_HOME not found: $java_home"
    export JAVA_HOME="$java_home"
    info "JAVA_HOME = $java_home"
  else
    info "JAVA_HOME not set; relying on system JDK discovery"
  fi

  # Build via root CMakeLists.txt with TD_ANDROID_JSON_JAVA=ON to produce
  # the proper tdjni shared library (libtdjsonjava) with td_jni.cpp.
  # TD_PACK_STATIC_DEPS=ON ensures OpenSSL is statically linked so
  # the resulting .so/.dylib is portable (zlib is system-provided on macOS/Linux).
  # CC/CXX/CXXFLAGS are read from environment by CMake (3.21+ auto-detects
  # compiler launchers like ccache from CC="ccache clang-18").
  mkdir -p "$build_subdir"
  cmake -S "$PROJECT_ROOT" \
        -B "$build_subdir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DTD_ANDROID_JSON_JAVA=ON \
        -DTD_PACK_STATIC_DEPS=ON \
        "${extra_args[@]}" \
        2>&1 | sed 's/^/  /'

  cmake --build "$build_subdir" \
        --target tdjni \
        --config Release \
        -j"$NPROC" \
        2>&1 | sed 's/^/  /'

  # Manual copy of shared library
  mkdir -p "$out_dir/lib"

  if [[ "$os" == "macos" ]]; then
    cp -av "$build_subdir"/libtdjsonjava*.dylib "$out_dir/lib/" 2>/dev/null || true
  else
    # Linux .so files (exclude .so.debug which contains unstripped symbols)
    cp -av "$build_subdir"/libtdjsonjava*.so "$out_dir/lib/" 2>/dev/null || true
  fi

  success "JNI build complete → $out_dir"
}

# ── Android JNI ───────────────────────────────────────────────────────────────
build_android_jni() {
  local abi="$1"  # arm64-v8a | armeabi-v7a | x86_64 | x86

  local openssl_dir="$PROJECT_ROOT/third_party/openssl/android/${abi}"
  local out_dir="$PROJECT_ROOT/out/android/${abi}"
  local build_subdir="$BUILD_DIR/android-jni-${abi}"

  banner "Building TDLib JNI — Android/${abi}"

  # Validate prerequisites
  if [[ -z "${ANDROID_NDK_ROOT:-}" && -z "${ANDROID_NDK:-}" ]]; then
    error "ANDROID_NDK_ROOT (or ANDROID_NDK) must be set to the NDK root directory."
  fi
  NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK}}"
  [[ -d "$NDK_ROOT" ]] || error "NDK directory not found: $NDK_ROOT"

  if [[ ! -d "$openssl_dir" ]]; then
    error "OpenSSL for Android/${abi} not found at $openssl_dir.\n" \
          "Run: ./scripts/build-openssl-android.sh first."
  fi

  # Detect NDK version for toolchain file path
  local toolchain_file="$NDK_ROOT/build/cmake/android.toolchain.cmake"
  [[ -f "$toolchain_file" ]] || error "NDK toolchain file not found: $toolchain_file"

  local min_sdk=21

  prepare_cross_compiling

  mkdir -p "$build_subdir"
  cmake -S "$TD_DIR/example/android" \
        -B "$build_subdir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain_file" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM="android-${min_sdk}" \
        -DANDROID_STL=c++_static \
        -DTD_ANDROID_JSON_JAVA=ON \
        -DOPENSSL_ROOT_DIR="$openssl_dir" \
        -DNATIVE_GEN_DIR="$NATIVE_GEN_DIR" \
        2>&1 | sed 's/^/  /'

  cmake --build "$build_subdir" \
        --target tdjni \
        --config Release \
        -j"$NPROC" \
        2>&1 | sed 's/^/  /'

  # Manual copy of shared library
  mkdir -p "$out_dir"
  cp -v "$build_subdir"/libtdjsonjava.so "$out_dir/" 2>/dev/null || true

  success "Android JNI build complete → $out_dir"
}

# ── iOS static ────────────────────────────────────────────────────────────────
build_ios_static() {
  local arch_variant="$1"  # arm64 | arm64-simulator | x86_64-simulator

  local ios_platform openssl_platform out_dir build_subdir cmake_arch

  case "$arch_variant" in
    arm64)
      ios_platform="OS"
      openssl_platform="OS64"
      cmake_arch="arm64"
      ;;
    arm64-simulator)
      ios_platform="SIMULATOR"
      openssl_platform="SIMULATORARM64"
      cmake_arch="arm64"
      ;;
    x86_64-simulator)
      ios_platform="SIMULATOR"
      openssl_platform="SIMULATOR64"
      cmake_arch="x86_64"
      ;;
    *)
      error "Unknown iOS arch variant: $arch_variant"
      ;;
  esac

  out_dir="$PROJECT_ROOT/out/ios-${arch_variant}"
  build_subdir="$BUILD_DIR/ios-static-${arch_variant}"

  local openssl_ios_dir="$PROJECT_ROOT/third_party/openssl/ios"
  local openssl_plat_dir="$openssl_ios_dir/${openssl_platform}"

  if [[ ! -d "$openssl_plat_dir" ]]; then
    error "OpenSSL for iOS/${openssl_platform} not found at $openssl_plat_dir.\n" \
          "Run: ./scripts/build-openssl-ios.sh first."
  fi

  # Locate iOS.cmake toolchain (bundled in TDLib)
  local ios_toolchain="$TD_DIR/CMake/iOS.cmake"
  [[ -f "$ios_toolchain" ]] || error "iOS toolchain not found: $ios_toolchain"

  banner "Building TDLib static — ios-${arch_variant} (${ios_platform})"

  prepare_cross_compiling

  # The iOS.cmake toolchain restricts CMAKE_FIND_ROOT_PATH_MODE_PROGRAM to
  # ONLY, which prevents CMake from finding the host 'make' binary.  Resolve
  # it before cross-configure and pass it explicitly.
  local host_make
  host_make="$(command -v make)" || error "'make' not found on the host system"

  mkdir -p "$build_subdir"
  # The iOS.cmake toolchain sets CMAKE_FIND_ROOT_PATH_MODE_LIBRARY and
  # CMAKE_FIND_ROOT_PATH_MODE_INCLUDE to ONLY, so find_package(OpenSSL)
  # cannot locate libraries outside the iOS SDK sysroot.  Pass the paths
  # explicitly so CMake finds our cross-compiled OpenSSL.
  cmake -S "$TD_DIR" \
        -B "$build_subdir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS_RELEASE="$STATIC_RELEASE_FLAGS" \
        -DCMAKE_CXX_FLAGS_RELEASE="$STATIC_RELEASE_FLAGS" \
        -DCMAKE_TOOLCHAIN_FILE="$ios_toolchain" \
        -DIOS_PLATFORM="$ios_platform" \
        -DCMAKE_OSX_ARCHITECTURES="$cmake_arch" \
        -DCMAKE_MAKE_PROGRAM="$host_make" \
        -DTD_ENABLE_JNI=OFF \
        -DTD_ENABLE_LTO=OFF \
        -DOPENSSL_ROOT_DIR="$openssl_plat_dir" \
        -DOPENSSL_CRYPTO_LIBRARY="$openssl_plat_dir/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$openssl_plat_dir/lib/libssl.a" \
        -DOPENSSL_INCLUDE_DIR="$openssl_plat_dir/include" \
        2>&1 | sed 's/^/  /'

  cmake --build "$build_subdir" \
        --target tdjson_static \
        --config Release \
        -j"$NPROC" \
        2>&1 | sed 's/^/  /'

  # Manual copy of artifacts
  mkdir -p "$out_dir/lib"
  mkdir -p "$out_dir/include/td/telegram"

  # Copy all .a files from build dir (1 and 2 levels deep)
  cp -v "$build_subdir"/*.a "$out_dir/lib" 2>/dev/null || true
  cp -v "$build_subdir"/*/*.a "$out_dir/lib" 2>/dev/null || true

  # Copy OpenSSL static libraries
  cp -v "$openssl_plat_dir/lib/libcrypto.a" "$out_dir/lib" 2>/dev/null || true
  cp -v "$openssl_plat_dir/lib/libssl.a" "$out_dir/lib" 2>/dev/null || true

  # Strip local symbols/debug from all .a (incl. OpenSSL) to shrink the archive
  strip_static_libs "$out_dir/lib"

  # Copy specific headers
  cp -v "$build_subdir/td/telegram/tdjson_export.h" "$out_dir/include/td/telegram" 2>/dev/null || true
  cp -v "$TD_DIR/td/telegram/td_json_client.h" "$out_dir/include" 2>/dev/null || true
  cp -v "$TD_DIR/td/telegram/td_log.h" "$out_dir/include" 2>/dev/null || true

  success "iOS static build complete → $out_dir"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatch
# ═══════════════════════════════════════════════════════════════════════════════

case "$PLATFORM" in

  # ── macOS ──────────────────────────────────────────────────────────────────
  macos-arm64)
    if [[ "$TARGET" == "tdlib" ]]; then
      build_desktop_static macos arm64
    else
      apply_patch
      build_desktop_jni macos arm64
    fi
    ;;

  macos-x86_64)
    if [[ "$TARGET" == "tdlib" ]]; then
      build_desktop_static macos x86_64
    else
      apply_patch
      build_desktop_jni macos x86_64
    fi
    ;;

  # ── Linux ──────────────────────────────────────────────────────────────────
  linux-x86_64)
    if [[ "$TARGET" == "tdlib" ]]; then
      build_desktop_static linux x86_64
    else
      apply_patch
      build_desktop_jni linux x86_64
    fi
    ;;

  linux-arm64)
    if [[ "$TARGET" == "tdlib" ]]; then
      build_desktop_static linux arm64
    else
      apply_patch
      build_desktop_jni linux arm64
    fi
    ;;

  # ── Android ────────────────────────────────────────────────────────────────
  android-arm64-v8a)
    [[ "$TARGET" == "tdlib_jni" ]] || error "Android only supports target 'tdlib_jni'"
    apply_patch
    build_android_jni arm64-v8a
    ;;

  android-armeabi-v7a)
    [[ "$TARGET" == "tdlib_jni" ]] || error "Android only supports target 'tdlib_jni'"
    apply_patch
    build_android_jni armeabi-v7a
    ;;

  android-x86_64)
    [[ "$TARGET" == "tdlib_jni" ]] || error "Android only supports target 'tdlib_jni'"
    apply_patch
    build_android_jni x86_64
    ;;

  android-x86)
    [[ "$TARGET" == "tdlib_jni" ]] || error "Android only supports target 'tdlib_jni'"
    apply_patch
    build_android_jni x86
    ;;

  # ── iOS ────────────────────────────────────────────────────────────────────
  ios-arm64)
    [[ "$TARGET" == "tdlib" ]] || error "iOS only supports target 'tdlib'"
    build_ios_static arm64
    ;;

  ios-arm64-simulator)
    [[ "$TARGET" == "tdlib" ]] || error "iOS only supports target 'tdlib'"
    build_ios_static arm64-simulator
    ;;

  ios-x86_64-simulator)
    [[ "$TARGET" == "tdlib" ]] || error "iOS only supports target 'tdlib'"
    build_ios_static x86_64-simulator
    ;;

  *)
    error "Unhandled platform: $PLATFORM"
    ;;
esac

banner "Build finished successfully"
success "Target  : $TARGET"
success "Platform: $PLATFORM"

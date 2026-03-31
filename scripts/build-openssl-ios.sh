#!/usr/bin/env bash
# =============================================================================
# scripts/build-openssl-ios.sh
# Builds OpenSSL 3.1.5 static libraries for all iOS targets, then places them
# under:
#   third_party/openssl/ios/OS64/           — device arm64
#   third_party/openssl/ios/SIMULATORARM64/ — simulator arm64
#   third_party/openssl/ios/SIMULATOR64/    — simulator x86_64
#
# Does NOT use td/example/ios/build-openssl.sh (which relies on
# Python-Apple-support and generates invalid target triples on Xcode 16).
# Instead, OpenSSL is configured directly using darwin64-* targets with
# explicit -target flags so the correct triple is always used.
# =============================================================================
# Usage:
#   ./scripts/build-openssl-ios.sh
#
# No arguments required. Run from any directory.
# Requires: Xcode command-line tools, make, perl
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
OPENSSL_VERSION="3.1.5"
OPENSSL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
IOS_MIN_VERSION="12.0"
SIM_MIN_VERSION="12.0"

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

# ── Resolve project root ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/third_party/openssl/ios"
BUILD_TMP="/tmp/openssl-ios-$$"

# ── Platform check ────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  error "iOS builds require macOS. Current OS: $(uname)"
fi

if ! command -v xcrun &>/dev/null; then
  error "xcrun not found. Install Xcode command-line tools: xcode-select --install"
fi

# ── Obtain OpenSSL source ─────────────────────────────────────────────────────
download_openssl() {
  local tarball="$BUILD_TMP/openssl-${OPENSSL_VERSION}.tar.gz"
  mkdir -p "$BUILD_TMP"

  if [[ -f "$tarball" ]]; then
    info "Using cached tarball: $tarball"
    return 0
  fi

  info "Downloading OpenSSL $OPENSSL_VERSION …"
  if command -v curl &>/dev/null; then
    curl -fsSL "$OPENSSL_URL" -o "$tarball"
  elif command -v wget &>/dev/null; then
    wget -q "$OPENSSL_URL" -O "$tarball"
  else
    error "curl or wget required to download OpenSSL"
  fi
  success "Downloaded OpenSSL $OPENSSL_VERSION"
}

extract_openssl() {
  local src_dir="$BUILD_TMP/src"
  if [[ -d "$src_dir/openssl-${OPENSSL_VERSION}" ]]; then
    return 0
  fi
  mkdir -p "$src_dir"
  info "Extracting OpenSSL …"
  tar -xzf "$BUILD_TMP/openssl-${OPENSSL_VERSION}.tar.gz" -C "$src_dir"
}

# ── Build one iOS target ───────────────────────────────────────────────────────
# build_target <platform_name> <arch> <sdk> <is_simulator> <openssl_target>
build_target() {
  local platform_name="$1"   # OS64 | SIMULATORARM64 | SIMULATOR64
  local arch="$2"             # arm64 | x86_64
  local sdk="$3"              # iphoneos | iphonesimulator
  local is_sim="$4"           # true | false
  local openssl_target="$5"   # darwin64-arm64-cc | darwin64-x86_64-cc

  local out_dir="$OUTPUT_DIR/$platform_name"

  # Skip if already built
  if [[ -d "$out_dir/include" ]] && find "$out_dir/lib" -name "libssl.a" -quit 2>/dev/null | grep -q .; then
    info "OpenSSL for $platform_name already present, skipping"
    success "Platform $platform_name → $out_dir"
    return 0
  fi

  banner "Building OpenSSL ${OPENSSL_VERSION} for iOS/${platform_name} (${arch})"

  local sdk_path
  sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
  local clang
  clang=$(xcrun --sdk "$sdk" --find clang)

  # Build explicit -target triple to avoid double-simulator from iossimulator-xcrun
  local target_triple
  if [[ "$is_sim" == "true" ]]; then
    target_triple="${arch}-apple-ios${SIM_MIN_VERSION}-simulator"
  else
    target_triple="${arch}-apple-ios${IOS_MIN_VERSION}"
  fi

  # Min-version flag for the linker / crt selection
  local min_flag
  if [[ "$is_sim" == "true" ]]; then
    min_flag="-mios-simulator-version-min=${SIM_MIN_VERSION}"
  else
    min_flag="-miphoneos-version-min=${IOS_MIN_VERSION}"
  fi

  local build_dir="$BUILD_TMP/build-$platform_name"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  cp -R "$BUILD_TMP/src/openssl-${OPENSSL_VERSION}/." "$build_dir/"

  mkdir -p "$out_dir"

  (
    cd "$build_dir"

    # Override CC and CFLAGS so OpenSSL uses the correct target triple.
    # Using the darwin64-* configure targets (not ios64-cross / iossimulator-xcrun)
    # avoids the CROSS_COMPILE mechanism that appends an extra -simulator suffix.
    export CC="$clang"
    export CFLAGS="-arch $arch -target $target_triple -isysroot $sdk_path $min_flag"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-arch $arch -target $target_triple -isysroot $sdk_path $min_flag"

    ./Configure "$openssl_target" \
      --prefix="$out_dir" \
      no-shared \
      no-tests \
      no-dso \
      no-engine \
      no-comp \
      no-hw \
      no-async \
      2>&1 | sed 's/^/  /'

    make -j"$(sysctl -n hw.logicalcpu)" install_dev 2>&1 | sed 's/^/  /'
  )

  success "Platform $platform_name → $out_dir"
}

# ── Main ──────────────────────────────────────────────────────────────────────
banner "Building OpenSSL ${OPENSSL_VERSION} for iOS (all platforms)"
info "Output dir: $OUTPUT_DIR"

download_openssl
extract_openssl

# ┌─ Platform       ─ arch   ─ sdk               ─ sim   ─ openssl target ─────┐
build_target  OS64           arm64   iphoneos        false  darwin64-arm64-cc
build_target  SIMULATORARM64 arm64   iphonesimulator true   darwin64-arm64-cc
build_target  SIMULATOR64    x86_64  iphonesimulator true   darwin64-x86_64-cc

# Clean up temp build trees (keep the tarball for potential re-use)
rm -rf "$BUILD_TMP/build-"* "$BUILD_TMP/src" 2>/dev/null || true

banner "OpenSSL for iOS — done"
info "Outputs: $OUTPUT_DIR/{OS64,SIMULATORARM64,SIMULATOR64}/"
success "All iOS platforms built successfully"

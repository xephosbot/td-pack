#!/usr/bin/env bash
# =============================================================================
# scripts/build-openssl-ios.sh
# Builds OpenSSL static libraries for all three iOS targets directly, placing
# outputs under:
#   third_party/openssl/ios/{OS64,SIMULATORARM64,SIMULATOR64}/
#
# Uses darwin64-* OpenSSL configure targets with explicit CC/CFLAGS to set
# the correct clang target triple and sysroot.  This avoids the upstream
# Python-Apple-support Makefile which double-appends "-simulator" to the
# target triple for simulator SDKs.
# =============================================================================
# Usage:
#   ./scripts/build-openssl-ios.sh
#
# No arguments required. Run from any directory.
# Requires: Xcode command-line tools, make, curl
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

# ── Resolve project root ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT_DIR="$PROJECT_ROOT/third_party/openssl/ios"
BUILD_TMP="$PROJECT_ROOT/build/openssl-ios-tmp"
OPENSSL_VERSION="3.1.5"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
IOS_MIN_VERSION="12.0"

# ── Platform check ────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  error "iOS builds require macOS. Current OS: $(uname)"
fi

# ── Xcode check ──────────────────────────────────────────────────────────────
if ! command -v xcrun &>/dev/null; then
  error "xcrun not found. Install Xcode command-line tools: xcode-select --install"
fi

# ── Download OpenSSL source ──────────────────────────────────────────────────
download_openssl() {
  local tarball="$BUILD_TMP/openssl-${OPENSSL_VERSION}.tar.gz"
  if [[ -f "$tarball" ]]; then
    info "OpenSSL tarball already downloaded: $tarball"
    return 0
  fi
  mkdir -p "$BUILD_TMP"
  info "Downloading OpenSSL ${OPENSSL_VERSION}…"
  curl -fsSL "$OPENSSL_URL" -o "$tarball"
  success "Downloaded → $tarball"
}

# ── Extract OpenSSL source ───────────────────────────────────────────────────
extract_openssl() {
  local src_dir="$BUILD_TMP/src/openssl-${OPENSSL_VERSION}"
  if [[ -d "$src_dir" ]]; then
    info "OpenSSL source already extracted"
    return 0
  fi
  mkdir -p "$BUILD_TMP/src"
  info "Extracting OpenSSL source…"
  tar -xzf "$BUILD_TMP/openssl-${OPENSSL_VERSION}.tar.gz" -C "$BUILD_TMP/src"
  [[ -d "$src_dir" ]] || error "Expected source dir not found: $src_dir"
  success "Extracted → $src_dir"
}

# ── Build a single OpenSSL target ────────────────────────────────────────────
# Usage: build_target <PLATFORM_NAME> <ARCH> <SDK> <IS_SIMULATOR> <OPENSSL_TARGET>
build_target() {
  local platform_name="$1"  # OS64 | SIMULATORARM64 | SIMULATOR64
  local arch="$2"           # arm64 | x86_64
  local sdk="$3"            # iphoneos | iphonesimulator
  local is_sim="$4"         # true | false
  local openssl_target="$5" # darwin64-arm64-cc | darwin64-x86_64-cc

  local out_dir="$OUTPUT_DIR/$platform_name"

  # Skip if already built
  if [[ -f "$out_dir/lib/libcrypto.a" && -f "$out_dir/lib/libssl.a" ]]; then
    info "Platform $platform_name already built, skipping"
    success "Platform $platform_name → $out_dir"
    return 0
  fi

  banner "Building OpenSSL ${OPENSSL_VERSION} — $platform_name ($arch / $sdk)"

  local sdk_path
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local clang
  clang="$(xcrun --sdk "$sdk" --find clang)"

  # Construct target triple
  local target_triple
  if [[ "$is_sim" == "true" ]]; then
    target_triple="${arch}-apple-ios${IOS_MIN_VERSION}-simulator"
    local min_flag="-mios-simulator-version-min=${IOS_MIN_VERSION}"
  else
    target_triple="${arch}-apple-ios${IOS_MIN_VERSION}"
    local min_flag="-mios-version-min=${IOS_MIN_VERSION}"
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

  # Verify outputs
  if [[ -f "$out_dir/lib/libcrypto.a" && -f "$out_dir/lib/libssl.a" ]]; then
    success "Platform $platform_name → $out_dir"
  else
    error "Build succeeded but expected libraries not found in $out_dir/lib/"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
banner "Building OpenSSL ${OPENSSL_VERSION} for iOS (all platforms)"
info "Output dir: $OUTPUT_DIR"

download_openssl
extract_openssl

# ┌─ Platform         ─ arch   ─ sdk               ─ sim   ─ openssl target ───┐
build_target  OS64           arm64   iphoneos        false  darwin64-arm64-cc
build_target  SIMULATORARM64 arm64   iphonesimulator true   darwin64-arm64-cc
build_target  SIMULATOR64    x86_64  iphonesimulator true   darwin64-x86_64-cc

# Clean up temp build trees (keep the tarball for potential re-use)
rm -rf "$BUILD_TMP/build-"* "$BUILD_TMP/src" 2>/dev/null || true

banner "OpenSSL for iOS — done"
info "Outputs: $OUTPUT_DIR/{OS64,SIMULATORARM64,SIMULATOR64}/"

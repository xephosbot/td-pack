#!/usr/bin/env bash
# =============================================================================
# scripts/build-openssl-ios.sh
# Wraps td/example/ios/build-openssl.sh to produce OpenSSL static libs for
# all three iOS targets, then organises them under:
#   third_party/openssl/ios/{OS64,SIMULATORARM64,SIMULATOR64}/
# =============================================================================
# Usage:
#   ./scripts/build-openssl-ios.sh
#
# No arguments required. Run from any directory.
# Requires: Xcode command-line tools, cmake, make
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

# ── Platform check ────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  error "iOS builds require macOS. Current OS: $(uname)"
fi

# ── Validate upstream build script ───────────────────────────────────────────
UPSTREAM_SCRIPT="$PROJECT_ROOT/td/example/ios/build-openssl.sh"
if [[ ! -f "$UPSTREAM_SCRIPT" ]]; then
  error "Upstream build script not found: $UPSTREAM_SCRIPT\n" \
        "Make sure the TDLib submodule is initialised:\n  git submodule update --init --depth=1 td"
fi
if [[ ! -x "$UPSTREAM_SCRIPT" ]]; then
  chmod +x "$UPSTREAM_SCRIPT"
fi

# ── Xcode check ──────────────────────────────────────────────────────────────
if ! command -v xcrun &>/dev/null; then
  error "xcrun not found. Install Xcode command-line tools: xcode-select --install"
fi

banner "Building OpenSSL for iOS (all platforms)"
info "Output dir : $OUTPUT_DIR"

# ── Run upstream script ───────────────────────────────────────────────────────
# The TDLib ios/build-openssl.sh typically places its output inside
# td/example/ios/third_party/openssl/ organised by IOS_PLATFORM name.
# We run it from its own directory as it expects relative paths.

UPSTREAM_BUILD_DIR="$PROJECT_ROOT/td/example/ios"

banner "Running TDLib ios/build-openssl.sh"

pushd "$UPSTREAM_BUILD_DIR" > /dev/null
./build-openssl.sh 2>&1 | sed 's/^/  /'
popd > /dev/null

# ── Locate and organise outputs ───────────────────────────────────────────────
# The upstream script may put outputs in several places depending on TDLib version.
# Common layouts:
#   td/example/ios/third_party/openssl/{OS64,SIMULATORARM64,SIMULATOR64}/
#   td/example/ios/openssl/{OS64,SIMULATORARM64,SIMULATOR64}/
# We search for known subdirectory names and copy/link them.

PLATFORMS=(OS64 SIMULATORARM64 SIMULATOR64)

banner "Organising OpenSSL outputs under third_party/openssl/ios/"
mkdir -p "$OUTPUT_DIR"

# Search candidate source directories (order: preferred first)
CANDIDATE_ROOTS=(
  "$UPSTREAM_BUILD_DIR/third_party/openssl"
  "$UPSTREAM_BUILD_DIR/openssl"
  "$PROJECT_ROOT/td/example/ios/third_party/openssl"
)

find_platform_dir() {
  local plat="$1"
  for root in "${CANDIDATE_ROOTS[@]}"; do
    local candidate="$root/$plat"
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  # Fallback: deep search under td/example/ios
  local found
  found=$(find "$UPSTREAM_BUILD_DIR" -maxdepth 5 -type d -name "$plat" 2>/dev/null | head -1)
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi
  return 1
}

all_ok=true
for plat in "${PLATFORMS[@]}"; do
  dest="$OUTPUT_DIR/$plat"

  # Skip if already in place
  if [[ -d "$dest" ]]; then
    if find "$dest" -name "*.a" -print -quit 2>/dev/null | grep -q .; then
      info "Platform $plat already present at $dest, skipping copy"
      success "Platform $plat → $dest"
      continue
    fi
  fi

  src=$(find_platform_dir "$plat") || true
  if [[ -z "$src" || ! -d "$src" ]]; then
    warn "Could not locate OpenSSL output for platform: $plat"
    warn "Searched candidate roots:"
    for root in "${CANDIDATE_ROOTS[@]}"; do
      warn "  $root/$plat"
    done
    all_ok=false
    continue
  fi

  info "Copying $plat: $src → $dest"
  mkdir -p "$dest"
  # Use rsync when available for speed; fall back to cp -R
  if command -v rsync &>/dev/null; then
    rsync -a --delete "$src/" "$dest/" 2>&1 | sed 's/^/  /'
  else
    cp -R "$src/." "$dest/"
  fi

  # Verify at least one .a file was copied
  if find "$dest" -name "*.a" -print -quit 2>/dev/null | grep -q .; then
    success "Platform $plat → $dest"
  else
    warn "Platform $plat directory exists but contains no .a files: $dest"
    all_ok=false
  fi
done

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
      no-apps \
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

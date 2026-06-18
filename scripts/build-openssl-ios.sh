#!/usr/bin/env bash
# =============================================================================
# scripts/build-openssl-ios.sh
# Builds OpenSSL static libraries for all three iOS targets using the upstream
# td/example/ios/build-openssl.sh approach (Python-Apple-support). TDLib's own
# Python-Apple-support.patch already emits correct simulator target triples
# (arm64-apple-ios-simulator via OS_LOWER), so no extra triple-fix is needed.
#
# Produces outputs under:
#   third_party/openssl/ios/{OS64,SIMULATORARM64,SIMULATOR64}/
# =============================================================================
# Usage:
#   ./scripts/build-openssl-ios.sh
#
# No arguments required. Run from any directory.
# Requires: Xcode command-line tools, make, git
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

# ── Validate prerequisites ───────────────────────────────────────────────────
if ! command -v xcrun &>/dev/null; then
  error "xcrun not found. Install Xcode command-line tools: xcode-select --install"
fi

UPSTREAM_DIR="$PROJECT_ROOT/td/example/ios"
UPSTREAM_SCRIPT="$UPSTREAM_DIR/build-openssl.sh"
UPSTREAM_PATCH="$UPSTREAM_DIR/Python-Apple-support.patch"

if [[ ! -f "$UPSTREAM_SCRIPT" ]]; then
  error "Upstream build script not found: $UPSTREAM_SCRIPT\n" \
        "Make sure the TDLib submodule is initialised:\n  git submodule update --init --depth=1 td"
fi
[[ -x "$UPSTREAM_SCRIPT" ]] || chmod +x "$UPSTREAM_SCRIPT"

banner "Building OpenSSL for iOS (all platforms)"
info "Using upstream: $UPSTREAM_SCRIPT"
info "Output dir:     $OUTPUT_DIR"

# ── Clone Python-Apple-support & apply patches ────────────────────────────────
PAS_DIR="$UPSTREAM_DIR/Python-Apple-support"

# Clean any previous clone
rm -rf "$PAS_DIR"

info "Cloning Python-Apple-support…"
git clone https://github.com/beeware/Python-Apple-support "$PAS_DIR" 2>&1 | sed 's/^/  /'

pushd "$PAS_DIR" > /dev/null
# Checkout the exact commit that TDLib's Python-Apple-support.patch targets
git checkout 6f43aba0ddd5a9f52f39775d0141bd4363614020 || error "Failed to checkout target commit"
git reset --hard || error "git reset failed"

info "Applying TDLib's Python-Apple-support patch…"
git apply "$UPSTREAM_PATCH" || error "Failed to apply TDLib patch"

success "Patch applied"
popd > /dev/null

# ── Build OpenSSL for iOS & iOS-simulator ─────────────────────────────────────
# We only need iOS targets (not macOS, tvOS, watchOS, visionOS).
# Run 'make' inside Python-Apple-support for the two iOS platform variants.

pushd "$PAS_DIR" > /dev/null

banner "Building OpenSSL-iOS (device arm64)"
make OpenSSL-iOS 2>&1 | sed 's/^/  /'

banner "Building OpenSSL-iOS-simulator (arm64 + x86_64)"
make OpenSSL-iOS-simulator 2>&1 | sed 's/^/  /'

popd > /dev/null

# ── Organise outputs ─────────────────────────────────────────────────────────
# The upstream Makefile produces:
#   Python-Apple-support/merge/iOS/openssl/{lib,include}/       (arm64 device)
#   Python-Apple-support/merge/iOS-simulator/openssl/{lib,include}/ (arm64+x86_64 fat)
#
# build.sh expects:
#   third_party/openssl/ios/OS64/{lib,include}/           (arm64 device)
#   third_party/openssl/ios/SIMULATORARM64/{lib,include}/ (arm64 simulator)
#   third_party/openssl/ios/SIMULATOR64/{lib,include}/    (x86_64 simulator)
#
# The fat simulator libs contain both arch slices, which CMake/clang handles
# correctly — they pick the appropriate slice for the target architecture.

banner "Organising OpenSSL outputs"
mkdir -p "$OUTPUT_DIR"

IOS_MERGE="$PAS_DIR/merge/iOS/openssl"
SIM_MERGE="$PAS_DIR/merge/iOS-simulator/openssl"

# Verify upstream outputs exist
for d in "$IOS_MERGE" "$SIM_MERGE"; do
  if [[ ! -d "$d/lib" || ! -d "$d/include" ]]; then
    error "Expected OpenSSL output not found: $d"
  fi
done

# OS64 ← iOS device (arm64)
info "Copying iOS device → OS64"
rm -rf "$OUTPUT_DIR/OS64"
mkdir -p "$OUTPUT_DIR/OS64"
cp -R "$IOS_MERGE/lib"     "$OUTPUT_DIR/OS64/"
cp -R "$IOS_MERGE/include" "$OUTPUT_DIR/OS64/"
success "OS64 → $OUTPUT_DIR/OS64"

# SIMULATORARM64 ← iOS-simulator (fat lib, arm64 slice used by CMake)
info "Copying iOS-simulator → SIMULATORARM64"
rm -rf "$OUTPUT_DIR/SIMULATORARM64"
mkdir -p "$OUTPUT_DIR/SIMULATORARM64"
cp -R "$SIM_MERGE/lib"     "$OUTPUT_DIR/SIMULATORARM64/"
cp -R "$SIM_MERGE/include" "$OUTPUT_DIR/SIMULATORARM64/"
success "SIMULATORARM64 → $OUTPUT_DIR/SIMULATORARM64"

# SIMULATOR64 ← iOS-simulator (same fat lib, x86_64 slice used by CMake)
info "Copying iOS-simulator → SIMULATOR64"
rm -rf "$OUTPUT_DIR/SIMULATOR64"
mkdir -p "$OUTPUT_DIR/SIMULATOR64"
cp -R "$SIM_MERGE/lib"     "$OUTPUT_DIR/SIMULATOR64/"
cp -R "$SIM_MERGE/include" "$OUTPUT_DIR/SIMULATOR64/"
success "SIMULATOR64 → $OUTPUT_DIR/SIMULATOR64"

# ── Clean up ─────────────────────────────────────────────────────────────────
rm -rf "$PAS_DIR"

banner "OpenSSL for iOS — done"
info "Outputs: $OUTPUT_DIR/{OS64,SIMULATORARM64,SIMULATOR64}/"

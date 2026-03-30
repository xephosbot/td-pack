#!/usr/bin/env bash
# =============================================================================
# scripts/build-openssl-android.sh
# Wraps td/example/android/build-openssl.sh to produce OpenSSL static libs
# for all four Android ABIs, placing them under:
#   third_party/openssl/android/{arm64-v8a,armeabi-v7a,x86_64,x86}/
# =============================================================================
# Usage:
#   ./scripts/build-openssl-android.sh [SDK_PATH [NDK_VERSION]]
#
# Arguments:
#   SDK_PATH     Path to the Android SDK (default: ./build/android-sdk)
#   NDK_VERSION  NDK version string   (default: 23.2.8568313)
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

# ── Arguments ─────────────────────────────────────────────────────────────────
DEFAULT_SDK_PATH="$PROJECT_ROOT/build/android-sdk"
DEFAULT_NDK_VERSION="23.2.8568313"

SDK_PATH="${1:-${ANDROID_SDK_ROOT:-$DEFAULT_SDK_PATH}}"
NDK_VERSION="${2:-$DEFAULT_NDK_VERSION}"

OUTPUT_DIR="$PROJECT_ROOT/third_party/openssl/android"

banner "Building OpenSSL for Android (all ABIs)"
info "SDK path    : $SDK_PATH"
info "NDK version : $NDK_VERSION"
info "Output dir  : $OUTPUT_DIR"

# ── Validate SDK path ─────────────────────────────────────────────────────────
if [[ ! -d "$SDK_PATH" ]]; then
  warn "Android SDK not found at: $SDK_PATH"
  warn "Run td/example/android/fetch-sdk.sh first, or set ANDROID_SDK_ROOT."
  echo ""
  echo "  Example:"
  echo "    cd $PROJECT_ROOT/td/example/android"
  echo "    ./fetch-sdk.sh $SDK_PATH"
  echo ""
  error "Android SDK not found. Aborting."
fi

# ── Validate NDK is installed ─────────────────────────────────────────────────
NDK_PATH="$SDK_PATH/ndk/$NDK_VERSION"
if [[ ! -d "$NDK_PATH" ]]; then
  error "NDK $NDK_VERSION not found at $NDK_PATH.\n" \
        "Make sure the SDK was fetched with fetch-sdk.sh and the correct NDK version is installed."
fi
info "NDK path    : $NDK_PATH"

# ── Validate upstream build script ───────────────────────────────────────────
UPSTREAM_SCRIPT="$PROJECT_ROOT/td/example/android/build-openssl.sh"
if [[ ! -f "$UPSTREAM_SCRIPT" ]]; then
  error "Upstream build script not found: $UPSTREAM_SCRIPT\n" \
        "Make sure the TDLib submodule is initialised:\n  git submodule update --init --depth=1 td"
fi
if [[ ! -x "$UPSTREAM_SCRIPT" ]]; then
  chmod +x "$UPSTREAM_SCRIPT"
fi

# ── Run upstream script ───────────────────────────────────────────────────────
banner "Running TDLib build-openssl.sh"

mkdir -p "$OUTPUT_DIR"

# The official script expects to be called from its own directory so that it
# can find its helper scripts (build-openssl-arch.sh etc.).
pushd "$PROJECT_ROOT/td/example/android" > /dev/null

# Signature: build-openssl.sh <SDK_PATH> <NDK_VERSION> [OUTPUT_DIR]
# Some versions accept a third argument; pass it unconditionally — the script
# will ignore extra args if it doesn't support them.
./build-openssl.sh "$SDK_PATH" "$NDK_VERSION" "$OUTPUT_DIR" 2>&1 | sed 's/^/  /'

popd > /dev/null

# ── Verify outputs ────────────────────────────────────────────────────────────
banner "Verifying output directories"

EXPECTED_ABIS=(arm64-v8a armeabi-v7a x86_64 x86)
all_ok=true

for abi in "${EXPECTED_ABIS[@]}"; do
  abi_dir="$OUTPUT_DIR/$abi"
  if [[ -d "$abi_dir" ]]; then
    # Check that at least one .a file exists
    if find "$abi_dir" -name "*.a" -print -quit 2>/dev/null | grep -q .; then
      success "ABI $abi → $abi_dir"
    else
      warn "ABI $abi directory exists but contains no .a files: $abi_dir"
      all_ok=false
    fi
  else
    error "ABI $abi output directory missing: $abi_dir"
    all_ok=false
  fi
done

if $all_ok; then
  success "All 4 ABIs built successfully"
else
  error "One or more ABI builds are incomplete. Check the output above."
fi

banner "OpenSSL for Android — done"
info "Outputs: $OUTPUT_DIR/{arm64-v8a,armeabi-v7a,x86_64,x86}/"

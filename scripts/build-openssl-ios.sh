#!/usr/bin/env bash
# =============================================================================
# scripts/build-openssl-ios.sh
# Builds OpenSSL static libraries for the three iOS slices DIRECTLY, using
# OpenSSL's native xcrun targets — no Python-Apple-support clone, no patch.
#
# Replaces the previous approach of cloning beeware/Python-Apple-support (a
# whole Python-for-Apple build system) at a pinned commit and patching it just
# to obtain OpenSSL: that pulled an external repo over the network and relied on
# a patch that rots whenever the td submodule updates.
#
# Mirrors scripts/build-openssl-macos.sh. Produces:
#   third_party/openssl/ios/OS64/{lib,include}/            (device  arm64)
#   third_party/openssl/ios/SIMULATORARM64/{lib,include}/  (sim     arm64)
#   third_party/openssl/ios/SIMULATOR64/{lib,include}/     (sim     x86_64)
# =============================================================================
# Usage:
#   ./scripts/build-openssl-ios.sh                 # all three slices
#   ./scripts/build-openssl-ios.sh OS64            # one slice
#
# Requires: Xcode + command-line tools (xcrun, clang), make, curl, perl
# =============================================================================

set -euo pipefail

# ── Tunables ──────────────────────────────────────────────────────────────────
OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.15}"
IOS_MIN="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'
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
WORK_DIR="$PROJECT_ROOT/build/openssl-ios-src"

# ── Platform checks ───────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || error "iOS builds require macOS. Current OS: $(uname)"
command -v xcrun &>/dev/null || error "xcrun not found. Install Xcode command-line tools: xcode-select --install"

# ── Which slices to build ──────────────────────────────────────────────────────
SLICES=("$@")
[[ ${#SLICES[@]} -gt 0 ]] || SLICES=(OS64 SIMULATORARM64 SIMULATOR64)

NPROC="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"

# ── Fetch source once ──────────────────────────────────────────────────────────
TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
SRC_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${TARBALL}"

banner "OpenSSL ${OPENSSL_VERSION} for iOS — slices: ${SLICES[*]}"
mkdir -p "$WORK_DIR"
if [[ ! -f "$WORK_DIR/$TARBALL" ]]; then
  info "Downloading $SRC_URL"
  curl -fsSL "$SRC_URL" -o "$WORK_DIR/$TARBALL" || error "Failed to download OpenSSL source"
fi
[[ -s "$WORK_DIR/$TARBALL" ]] || error "Downloaded tarball is empty: $WORK_DIR/$TARBALL"

# ── Build one slice ────────────────────────────────────────────────────────────
# OpenSSL's native targets:
#   ios64-xcrun         → xcrun -sdk iphoneos cc -arch arm64        (device)
#   iossimulator-xcrun  → xcrun -sdk iphonesimulator cc             (arch via CC override)
build_slice() {
  local name="$1"   # OS64 | SIMULATORARM64 | SIMULATOR64
  local cfg_target min_flag cc_override

  # The device target (ios64-xcrun) already bakes in -arch arm64. The simulator
  # target leaves the arch to the host default, so we pin it — but via a CC
  # override, NOT a bare "-arch <arch>" Configure arg: OpenSSL parses the bare
  # arch token as a second target name ("target already defined").
  case "$name" in
    OS64)
      cfg_target="ios64-xcrun"
      min_flag="-mios-version-min=${IOS_MIN}"
      cc_override="" ;;
    SIMULATORARM64)
      cfg_target="iossimulator-xcrun"
      min_flag="-mios-simulator-version-min=${IOS_MIN}"
      cc_override="CC=xcrun -sdk iphonesimulator cc -arch arm64" ;;
    SIMULATOR64)
      cfg_target="iossimulator-xcrun"
      min_flag="-mios-simulator-version-min=${IOS_MIN}"
      cc_override="CC=xcrun -sdk iphonesimulator cc -arch x86_64" ;;
    *)
      error "Unknown iOS slice: $name (use OS64, SIMULATORARM64 or SIMULATOR64)" ;;
  esac

  local src_dir="$WORK_DIR/${name}/openssl-${OPENSSL_VERSION}"
  local out_dir="$OUTPUT_DIR/${name}"

  banner "Building OpenSSL — ios/${name} (${cfg_target}${cc_override:+, ${cc_override#CC=}})"

  rm -rf "$WORK_DIR/${name}" "$out_dir"
  mkdir -p "$WORK_DIR/${name}" "$out_dir"
  tar -xzf "$WORK_DIR/$TARBALL" -C "$WORK_DIR/${name}"

  local extra=("$min_flag")
  [[ -n "$cc_override" ]] && extra+=("$cc_override")

  pushd "$src_dir" >/dev/null
  ./Configure "$cfg_target" \
      no-shared no-tests \
      --prefix="$out_dir" \
      --openssldir="$out_dir/ssl" \
      "${extra[@]}" \
      2>&1 | sed 's/^/  /'
  make -j"$NPROC" 2>&1 | sed 's/^/  /'
  make install_sw 2>&1 | sed 's/^/  /'   # libs + headers only (no docs)
  popd >/dev/null

  [[ -f "$out_dir/lib/libcrypto.a" && -f "$out_dir/lib/libssl.a" ]] \
    || error "OpenSSL build for $name did not produce static libs in $out_dir/lib"

  info "libcrypto.a arch: $(lipo -archs "$out_dir/lib/libcrypto.a" 2>/dev/null || echo '?')"
  success "ios/${name} → $out_dir"
}

for s in "${SLICES[@]}"; do
  build_slice "$s"
done

# ── Clean source trees (keep tarball cache + outputs) ─────────────────────────
for s in "${SLICES[@]}"; do rm -rf "$WORK_DIR/${s}"; done

banner "OpenSSL for iOS — done"
info "Outputs: $OUTPUT_DIR/{OS64,SIMULATORARM64,SIMULATOR64}/"

#!/usr/bin/env bash
# =============================================================================
# scripts/build-openssl-macos.sh
# Builds OpenSSL static libraries for macOS arm64 and x86_64 from source.
#
# This replaces the previous Rosetta hack (installing a full x86_64 Homebrew
# just to obtain x86_64 OpenSSL).  Apple clang cross-compiles x86_64 natively
# via OpenSSL's darwin64-x86_64-cc target — no Rosetta, no second Homebrew.
#
# Produces, mirroring the iOS/Android layout:
#   third_party/openssl/macos/arm64/{lib,include}/
#   third_party/openssl/macos/x86_64/{lib,include}/
# =============================================================================
# Usage:
#   ./scripts/build-openssl-macos.sh            # both arches
#   ./scripts/build-openssl-macos.sh arm64      # one arch
#
# Requires: Xcode command-line tools (clang), make, curl, perl
# =============================================================================

set -euo pipefail

# ── Tunables ──────────────────────────────────────────────────────────────────
OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.15}"
MACOS_MIN="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

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

OUTPUT_DIR="$PROJECT_ROOT/third_party/openssl/macos"
WORK_DIR="$PROJECT_ROOT/build/openssl-macos-src"

# ── Platform check ────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || error "macOS builds require macOS. Current OS: $(uname)"
command -v clang &>/dev/null || error "clang not found. Install Xcode command-line tools: xcode-select --install"

# ── Which arches to build ──────────────────────────────────────────────────────
ARCHES=("$@")
[[ ${#ARCHES[@]} -gt 0 ]] || ARCHES=(arm64 x86_64)

# ── Parallelism ────────────────────────────────────────────────────────────────
NPROC="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"

# ── Fetch source once ──────────────────────────────────────────────────────────
TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
SRC_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${TARBALL}"

banner "OpenSSL ${OPENSSL_VERSION} for macOS — arches: ${ARCHES[*]}"
mkdir -p "$WORK_DIR"
if [[ ! -f "$WORK_DIR/$TARBALL" ]]; then
  info "Downloading $SRC_URL"
  curl -fsSL "$SRC_URL" -o "$WORK_DIR/$TARBALL" || error "Failed to download OpenSSL source"
fi
[[ -s "$WORK_DIR/$TARBALL" ]] || error "Downloaded tarball is empty: $WORK_DIR/$TARBALL"

# ── Build per arch ─────────────────────────────────────────────────────────────
build_arch() {
  local arch="$1"
  local target
  case "$arch" in
    arm64)  target="darwin64-arm64-cc"  ;;
    x86_64) target="darwin64-x86_64-cc" ;;
    *)      error "Unsupported macOS arch: $arch (use arm64 or x86_64)" ;;
  esac

  local src_dir="$WORK_DIR/${arch}/openssl-${OPENSSL_VERSION}"
  local out_dir="$OUTPUT_DIR/${arch}"

  banner "Building OpenSSL — macos/${arch} (${target})"

  rm -rf "$WORK_DIR/${arch}" "$out_dir"
  mkdir -p "$WORK_DIR/${arch}" "$out_dir"
  tar -xzf "$WORK_DIR/$TARBALL" -C "$WORK_DIR/${arch}"

  pushd "$src_dir" >/dev/null
  # no-apps is only valid on OpenSSL >= 3.2; 3.0.x rejects it. no-tests keeps
  # the build to just the libraries we install via install_sw.
  ./Configure "$target" \
      no-shared no-tests \
      --prefix="$out_dir" \
      --openssldir="$out_dir/ssl" \
      "-mmacosx-version-min=${MACOS_MIN}" \
      2>&1 | sed 's/^/  /'
  make -j"$NPROC" 2>&1 | sed 's/^/  /'
  make install_sw 2>&1 | sed 's/^/  /'   # libs + headers only (no docs)
  popd >/dev/null

  [[ -f "$out_dir/lib/libcrypto.a" && -f "$out_dir/lib/libssl.a" ]] \
    || error "OpenSSL build for $arch did not produce static libs in $out_dir/lib"

  # Sanity: confirm the slice is the architecture we asked for
  local got
  got="$(lipo -archs "$out_dir/lib/libcrypto.a" 2>/dev/null || echo '?')"
  info "libcrypto.a arch: $got"
  success "macos/${arch} → $out_dir"
}

for a in "${ARCHES[@]}"; do
  build_arch "$a"
done

# ── Clean source tree (keep tarball cache + outputs) ──────────────────────────
for a in "${ARCHES[@]}"; do rm -rf "$WORK_DIR/${a}"; done

banner "OpenSSL for macOS — done"
info "Outputs: $OUTPUT_DIR/{${ARCHES[*]// /,}}/"

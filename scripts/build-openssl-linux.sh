#!/usr/bin/env bash
# =============================================================================
# scripts/build-openssl-linux.sh
# Builds OpenSSL static libraries for Linux x86_64 and arm64 with the
# Kotlin/Native GCC toolchains (see scripts/get-linux-toolchain.sh).
#
# The system libssl-dev cannot be bundled into the static distribution: it is
# compiled against the runner's modern glibc and would poison the archives
# with symbols the K/N sysroot lacks. Building with the K/N toolchain keeps
# every object in the archive linkable against glibc 2.19/2.25.
#
# Produces, mirroring the macOS/iOS/Android layout:
#   third_party/openssl/linux/x86_64/{lib,include}/
#   third_party/openssl/linux/arm64/{lib,include}/
# =============================================================================
# Usage:
#   ./scripts/build-openssl-linux.sh            # both arches
#   ./scripts/build-openssl-linux.sh x86_64     # one arch
#
# Requires: Linux x86_64 host, make, curl, perl
# =============================================================================

set -euo pipefail

# ── Tunables ──────────────────────────────────────────────────────────────────
OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.15}"

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

OUTPUT_DIR="$PROJECT_ROOT/third_party/openssl/linux"
WORK_DIR="$PROJECT_ROOT/build/openssl-linux-src"

# ── Platform check ────────────────────────────────────────────────────────────
[[ "$(uname)" == "Linux" ]] || error "Linux builds require a Linux x86_64 host (K/N toolchains are x86_64-hosted ELF). Current OS: $(uname)"
[[ "$(uname -m)" == "x86_64" ]] || error "K/N toolchains are x86_64-hosted; current machine: $(uname -m)"

# ── Which arches to build ──────────────────────────────────────────────────────
ARCHES=("$@")
[[ ${#ARCHES[@]} -gt 0 ]] || ARCHES=(x86_64 arm64)

# ── Parallelism ────────────────────────────────────────────────────────────────
NPROC="$(nproc 2>/dev/null || echo 4)"

# ── Fetch source once ──────────────────────────────────────────────────────────
TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
SRC_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${TARBALL}"

banner "OpenSSL ${OPENSSL_VERSION} for Linux (K/N toolchains) — arches: ${ARCHES[*]}"
mkdir -p "$WORK_DIR"
if [[ ! -f "$WORK_DIR/$TARBALL" ]]; then
  info "Downloading $SRC_URL"
  curl -fsSL "$SRC_URL" -o "$WORK_DIR/$TARBALL" || error "Failed to download OpenSSL source"
fi
[[ -s "$WORK_DIR/$TARBALL" ]] || error "Downloaded tarball is empty: $WORK_DIR/$TARBALL"

# ── Build per arch ─────────────────────────────────────────────────────────────
build_arch() {
  local arch="$1"
  local target triple
  case "$arch" in
    x86_64) target="linux-x86_64";  triple="x86_64-unknown-linux-gnu"  ;;
    arm64)  target="linux-aarch64"; triple="aarch64-unknown-linux-gnu" ;;
    *)      error "Unsupported Linux arch: $arch (use x86_64 or arm64)" ;;
  esac

  local toolchain
  toolchain="$("$SCRIPT_DIR/get-linux-toolchain.sh" "$arch")"

  local src_dir="$WORK_DIR/${arch}/openssl-${OPENSSL_VERSION}"
  local out_dir="$OUTPUT_DIR/${arch}"

  banner "Building OpenSSL — linux/${arch} (${target}, gcc 8.3)"

  rm -rf "$WORK_DIR/${arch}" "$out_dir"
  mkdir -p "$WORK_DIR/${arch}" "$out_dir"
  tar -xzf "$WORK_DIR/$TARBALL" -C "$WORK_DIR/${arch}"

  pushd "$src_dir" >/dev/null
  # no-apps is only valid on OpenSSL >= 3.2; 3.0.x rejects it. no-tests keeps
  # the build to just the libraries we install via install_sw.
  CC="$toolchain/bin/${triple}-gcc" \
  AR="$toolchain/bin/${triple}-ar" \
  RANLIB="$toolchain/bin/${triple}-ranlib" \
  ./Configure "$target" \
      no-shared no-tests \
      --prefix="$out_dir" \
      --openssldir="$out_dir/ssl" \
      2>&1 | sed 's/^/  /'
  make -j"$NPROC" 2>&1 | sed 's/^/  /'
  make install_sw 2>&1 | sed 's/^/  /'   # libs + headers only (no docs)
  popd >/dev/null

  # OpenSSL 3.x installs static libs to lib64/ on linux-x86_64; normalise to lib/
  if [[ -d "$out_dir/lib64" && ! -f "$out_dir/lib/libcrypto.a" ]]; then
    mkdir -p "$out_dir/lib"
    mv "$out_dir/lib64"/*.a "$out_dir/lib/" 2>/dev/null || true
    mv "$out_dir/lib64"/pkgconfig "$out_dir/lib/" 2>/dev/null || true
  fi

  [[ -f "$out_dir/lib/libcrypto.a" && -f "$out_dir/lib/libssl.a" ]] \
    || error "OpenSSL build for $arch did not produce static libs in $out_dir/lib"

  success "linux/${arch} → $out_dir"
}

for a in "${ARCHES[@]}"; do
  build_arch "$a"
done

# ── Clean source tree (keep tarball cache + outputs) ──────────────────────────
for a in "${ARCHES[@]}"; do rm -rf "$WORK_DIR/${a}"; done

banner "OpenSSL for Linux — done"
info "Outputs: $OUTPUT_DIR/{${ARCHES[*]// /,}}/"

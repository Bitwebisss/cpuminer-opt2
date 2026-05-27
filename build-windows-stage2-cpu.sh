#!/bin/bash
#
# build-windows-stage2-cpu.sh
# Builds CPU-only (no GPU) cpuminer exe for all 8 CPU arch variants.
#
# Called by build-windows-cpu.bat via MSYS2 UCRT64 bash.
# Can also be run manually inside MSYS2 UCRT64 terminal:
#
#   bash build-windows-stage2-cpu.sh [project_dir]
#
# No CUDA, no VS2019, no libmm_gpu_gate.dll required.
# Output: cpuminer-windows.zip in project root.

set -e

# ============================================================
#  QUICK TEST MODE — set to 1 to build only one variant
# ============================================================
QUICK_TEST=0
QUICK_VARIANT="cpuminer-sse2.exe"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
found() { echo -e "${CYAN}[FOUND]${NC} $*"; }

# ============================================================
#  RESOLVE PROJECT DIR
# ============================================================
if [ -n "$1" ]; then
    PROJECT_DIR="$1"
else
    PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

RELEASE_NOGPU="$PROJECT_DIR/release-windows/nogpu"

DEFAULT_CFLAGS="-maes -O3 -Wall"
DEFAULT_CFLAGS_OLD="-O3 -Wall"

info "Project dir: $PROJECT_DIR"
[ "$QUICK_TEST" = "1" ] && warn "QUICK TEST MODE: building only $QUICK_VARIANT"

# ============================================================
#  ENSURE UCRT64 TOOLCHAIN IN PATH
# ============================================================
export PATH="/ucrt64/bin:/usr/bin:$PATH"

# ============================================================
#  CHECK REQUIRED MSYS2 PACKAGES
# ============================================================
info "Checking MSYS2 packages..."
REQUIRED_PKGS=(
    mingw-w64-ucrt-x86_64-gcc
    mingw-w64-ucrt-x86_64-curl
    mingw-w64-ucrt-x86_64-jansson
    mingw-w64-ucrt-x86_64-gmp
    mingw-w64-ucrt-x86_64-openssl
    autoconf
    automake
    libtool
    pkg-config
    zip
)
MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    pacman -Q "$pkg" &>/dev/null || MISSING+=("$pkg")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    warn "Installing missing packages: ${MISSING[*]}"
    pacman -S --noconfirm "${MISSING[@]}" || error "Failed to install packages"
fi
info "Packages OK"

# ============================================================
#  CONFIGURE ARGS
# ============================================================
CONF_NOGPU="--with-curl=/ucrt64 --host=x86_64-w64-mingw32 LDFLAGS=-L/ucrt64/lib CPPFLAGS=-I/ucrt64/include"

# ============================================================
#  REGENERATE CONFIGURE (once, before all variants)
# ============================================================
cd "$PROJECT_DIR"
info "Running autogen.sh..."
./autogen.sh

# ============================================================
#  verify_and_copy_dlls  REL_DIR
#  Iteratively copies all UCRT64 runtime DLLs needed by
#  any exe/dll currently in REL_DIR. Re-scans after each copy
#  to catch transitive dependencies. Fails immediately if a
#  required DLL is not in the toolchain.
# ============================================================
verify_and_copy_dlls() {
    local rel_dir="$1"
    local changed=1

    while [ "$changed" = "1" ]; do
        changed=0
        local targets
        targets=$(find "$rel_dir" -maxdepth 1 \( -name "*.exe" -o -name "*.dll" \) 2>/dev/null)
        [ -z "$targets" ] && break

        local dlls
        dlls=$(ldd $targets 2>/dev/null \
            | grep -i "ucrt64\|mingw" \
            | awk '{print $3}' \
            | grep "^/" \
            | sort -u)

        for dll in $dlls; do
            local dllname
            dllname=$(basename "$dll")
            if [ -f "$rel_dir/$dllname" ]; then
                found "    $dllname — SKIP COPY"
                continue
            fi
            [ -f "$dll" ] || error "Required DLL missing from toolchain: $dll"
            cp "$dll" "$rel_dir/$dllname" || error "Copy failed: $dll → $rel_dir/"
            info "    Copied: $dllname"
            changed=1
        done
    done
}

# ============================================================
#  build_variant  CFLAGS  NAME  CONF_ARGS  OUT_DIR
#
#  Sequence per variant:
#    1. make distclean       — removes .o, exe, Makefile, config.status,
#                              config.cache, config.log — NO leftovers
#    2. ./configure          — 100% fresh configure with current flags
#    3. make -j              — compile
#    4. strip + copy exe
#    5. verify_and_copy_dlls — runtime DLL check (fail-fast)
#
#  WHY distclean and NOT (make clean + rm config.status):
#    make clean   leaves config.cache — cached ./configure results that
#    can bleed into the next variant (wrong arch flags).
#    make distclean wipes everything ./configure ever wrote.
# ============================================================
build_variant() {
    local cflags="$1"
    local name="$2"
    local conf_args="$3"
    local out_dir="$4"

    if [ "$QUICK_TEST" = "1" ] && [ "$name" != "$QUICK_VARIANT" ]; then
        info "  Skipping $name (quick test mode)"
        return 0
    fi

    info ""
    info "  ── Building $name ──"

    # Full clean: wipes obj files, exe, Makefile, config.cache, config.status,
    # config.log — everything ./configure wrote. Prevents ANY bleed between
    # variants (different CPU arch flags, cached values).
    make distclean 2>/dev/null || true

    export CFLAGS="$cflags"
    ./configure $conf_args 2>&1 | grep -E "(checking|error|warning)" | tail -5 || true
    make -j$(nproc) 2>&1 | tail -3
    strip -s cpuminer.exe
    cp cpuminer.exe "$out_dir/$name"
    info "  ✓ $name compiled"

    info "  Verifying runtime DLLs for $name..."
    verify_and_copy_dlls "$out_dir"

    info "  ✓ $name — all dependencies OK"
}

# ============================================================
#  BUILD ALL CPU-ONLY VARIANTS
# ============================================================
info ""
info "========================================"
info "  Building CPU-only variants (8 CPU archs)"
info "========================================"

# Wipe release dir once before starting — ensures no stale exe/dll
# from a previous run.
info "Cleaning release dir: $RELEASE_NOGPU"
rm -rf "$RELEASE_NOGPU"
mkdir -p "$RELEASE_NOGPU"

build_variant "-march=icelake-client $DEFAULT_CFLAGS"       "cpuminer-avx512-sha-vaes.exe" "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-march=skylake-avx512 $DEFAULT_CFLAGS"       "cpuminer-avx512.exe"          "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-mavx2 -msha -mvaes $DEFAULT_CFLAGS"         "cpuminer-avx2-sha-vaes.exe"   "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-march=znver1 $DEFAULT_CFLAGS"               "cpuminer-avx2-sha.exe"        "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-march=core-avx2 $DEFAULT_CFLAGS"            "cpuminer-avx2.exe"            "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD" "cpuminer-avx.exe"             "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-march=westmere -maes $DEFAULT_CFLAGS_OLD"   "cpuminer-aes-sse42.exe"       "$CONF_NOGPU" "$RELEASE_NOGPU"
build_variant "-msse2 $DEFAULT_CFLAGS_OLD"                  "cpuminer-sse2.exe"            "$CONF_NOGPU" "$RELEASE_NOGPU"

# ============================================================
#  DOCUMENTATION
# ============================================================
info "Copying documentation..."
for f in README.txt README.md RELEASE_NOTES verthash-help.txt; do
    [ -f "$PROJECT_DIR/$f" ] && cp "$PROJECT_DIR/$f" "$RELEASE_NOGPU/" || true
done

# ============================================================
#  HASHES
# ============================================================
info "Generating SHA-256 hashes..."
(cd "$RELEASE_NOGPU" && sha256sum *.exe *.dll 2>/dev/null > hashes.txt || true)

# ============================================================
#  ZIP
# ============================================================
info "Creating zip archive..."
rm -f "$PROJECT_DIR/cpuminer-windows.zip"
(cd "$RELEASE_NOGPU" && zip -r "$PROJECT_DIR/cpuminer-windows.zip" .)
info "  Created: cpuminer-windows.zip"

# ============================================================
#  SUMMARY
# ============================================================
info ""
info "========================================"
info "  CPU-only build complete."
info "  Archive: cpuminer-windows.zip"
info ""
info "  CPU arch reference:"
info "    avx512-sha-vaes  Intel Icelake, Rocketlake"
info "    avx512           Intel Skylake-X, Cascadelake"
info "    avx2-sha-vaes    Intel Alderlake, AMD Zen3+"
info "    avx2-sha         AMD Zen1 / Zen2"
info "    avx2             Intel Haswell to Cometlake"
info "    avx              Intel Sandybridge / Ivybridge"
info "    aes-sse42        Intel Westmere"
info "    sse2             Generic x64 fallback"
info "========================================"

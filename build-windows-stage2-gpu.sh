#!/bin/bash
#
# build-windows-stage2-gpu.sh
# Builds GPU-enabled cpuminer exe for all 8 CPU arch variants.
#
# Called by build-windows-gpu.bat via MSYS2 UCRT64 bash.
# Can also be run manually inside MSYS2 UCRT64 terminal:
#
#   CPUMINER_GPU_GATE_WIN="C:/path/to/argon2-gpu/build_vs/Release" \
#   bash build-windows-stage2-gpu.sh [project_dir]
#
# Requires Stage 1 (libmm_gpu_gate.dll + .dll.a) to be built first.
# Output: cpuminer-windows-gpu.zip in project root.

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

if [ -n "$CPUMINER_GPU_GATE_WIN" ]; then
    GPU_GATE_DIR=$(cygpath -u "$CPUMINER_GPU_GATE_WIN")
else
    GPU_GATE_DIR="$PROJECT_DIR/algo/argon2d/argon2-gpu/build_vs/Release"
fi

RELEASE_GPU="$PROJECT_DIR/release-windows/gpu"

DEFAULT_CFLAGS="-maes -O3 -Wall"
DEFAULT_CFLAGS_OLD="-O3 -Wall"

info "Project dir : $PROJECT_DIR"
info "GPU gate dir: $GPU_GATE_DIR"
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
    mingw-w64-ucrt-x86_64-opencl-icd
    mingw-w64-ucrt-x86_64-opencl-headers
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
#  VALIDATE GPU GATE FILES
# ============================================================
[ -f "$GPU_GATE_DIR/libmm_gpu_gate.dll" ]   || error "libmm_gpu_gate.dll not found in $GPU_GATE_DIR — run build-windows-gpu.bat (Stage 1) first"
[ -f "$GPU_GATE_DIR/libmm_gpu_gate.dll.a" ] || error "libmm_gpu_gate.dll.a not found in $GPU_GATE_DIR — run build-windows-gpu.bat (Stage 1) first"
[ -f "$PROJECT_DIR/algo/argon2d/argon2-gpu/data/kernels/argon2_kernel.cl" ] \
    || error "argon2_kernel.cl not found — check your source tree"

# ============================================================
#  CONFIGURE ARGS
# ============================================================
CONF_BASE="--with-curl=/ucrt64 --host=x86_64-w64-mingw32 LDFLAGS=-L/ucrt64/lib CPPFLAGS=-I/ucrt64/include"
CONF_GPU="--enable-gpu --with-mm-gpu-gate=$GPU_GATE_DIR $CONF_BASE"

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
#  verify_and_copy_gpu_files  REL_DIR
#  Copies libmm_gpu_gate.dll and argon2_kernel.cl if absent.
# ============================================================
verify_and_copy_gpu_files() {
    local rel_dir="$1"

    if [ -f "$rel_dir/libmm_gpu_gate.dll" ]; then
        found "    libmm_gpu_gate.dll — SKIP COPY"
    else
        cp "$GPU_GATE_DIR/libmm_gpu_gate.dll" "$rel_dir/" \
            || error "Copy failed: libmm_gpu_gate.dll"
        info "    Copied: libmm_gpu_gate.dll"
    fi

    local kernel_dst="$rel_dir/data/kernels"
    mkdir -p "$kernel_dst"
    if [ -f "$kernel_dst/argon2_kernel.cl" ]; then
        found "    argon2_kernel.cl — SKIP COPY"
    else
        cp "$PROJECT_DIR/algo/argon2d/argon2-gpu/data/kernels/argon2_kernel.cl" "$kernel_dst/" \
            || error "Copy failed: argon2_kernel.cl"
        info "    Copied: data/kernels/argon2_kernel.cl"
    fi
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
#    6. verify_and_copy_gpu_files — GPU file check (fail-fast)
#
#  WHY distclean and NOT (make clean + rm config.status):
#    make clean   leaves config.cache — cached ./configure results that
#    can bleed into the next variant (wrong arch flags, wrong GPU flags).
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
    # variants (different CPU arch flags, GPU vs no-GPU flags, cached values).
    # The explicit rm is a safety net in case distclean is unavailable
    # (no Makefile on first run, or distclean not defined in this autotools version).
    make distclean 2>/dev/null || true
    rm -f config.cache config.status config.log

    export CFLAGS="$cflags"
    ./configure $conf_args 2>&1 | grep -E "(checking|error|warning)" | tail -5 || true
    make -j$(nproc) 2>&1 | tail -3
    strip -s cpuminer.exe
    cp cpuminer.exe "$out_dir/$name"
    info "  ✓ $name compiled"

    info "  Verifying runtime DLLs for $name..."
    verify_and_copy_dlls "$out_dir"

    info "  Verifying GPU-specific files for $name..."
    verify_and_copy_gpu_files "$out_dir"

    info "  ✓ $name — all dependencies OK"
}

# ============================================================
#  BUILD ALL GPU VARIANTS
# ============================================================
info ""
info "========================================"
info "  Building GPU variants (8 CPU archs)"
info "========================================"

# Wipe release dir once before starting — ensures no stale exe/dll
# from a previous run (including an outdated libmm_gpu_gate.dll copy).
info "Cleaning release dir: $RELEASE_GPU"
rm -rf "$RELEASE_GPU"
mkdir -p "$RELEASE_GPU"

build_variant "-march=icelake-client $DEFAULT_CFLAGS"       "cpuminer-avx512-sha-vaes.exe" "$CONF_GPU" "$RELEASE_GPU"
build_variant "-march=skylake-avx512 $DEFAULT_CFLAGS"       "cpuminer-avx512.exe"          "$CONF_GPU" "$RELEASE_GPU"
build_variant "-mavx2 -msha -mvaes $DEFAULT_CFLAGS"         "cpuminer-avx2-sha-vaes.exe"   "$CONF_GPU" "$RELEASE_GPU"
build_variant "-march=znver1 $DEFAULT_CFLAGS"               "cpuminer-avx2-sha.exe"        "$CONF_GPU" "$RELEASE_GPU"
build_variant "-march=core-avx2 $DEFAULT_CFLAGS"            "cpuminer-avx2.exe"            "$CONF_GPU" "$RELEASE_GPU"
build_variant "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD" "cpuminer-avx.exe"             "$CONF_GPU" "$RELEASE_GPU"
build_variant "-march=westmere -maes $DEFAULT_CFLAGS_OLD"   "cpuminer-aes-sse42.exe"       "$CONF_GPU" "$RELEASE_GPU"
build_variant "-msse2 $DEFAULT_CFLAGS_OLD"                  "cpuminer-sse2.exe"            "$CONF_GPU" "$RELEASE_GPU"

# ============================================================
#  DOCUMENTATION
# ============================================================
info "Copying documentation..."
for f in README.txt README.md RELEASE_NOTES verthash-help.txt; do
    [ -f "$PROJECT_DIR/$f" ] && cp "$PROJECT_DIR/$f" "$RELEASE_GPU/" || true
done

# ============================================================
#  HASHES
# ============================================================
info "Generating SHA-256 hashes..."
(cd "$RELEASE_GPU" && sha256sum *.exe *.dll 2>/dev/null > hashes.txt || true)

# ============================================================
#  ZIP
# ============================================================
info "Creating zip archive..."
rm -f "$PROJECT_DIR/cpuminer-windows-gpu.zip"
(cd "$RELEASE_GPU" && zip -r "$PROJECT_DIR/cpuminer-windows-gpu.zip" .)
info "  Created: cpuminer-windows-gpu.zip"

# ============================================================
#  SUMMARY
# ============================================================
info ""
info "========================================"
info "  Stage 2 GPU build complete."
info "  Archive: cpuminer-windows-gpu.zip"
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

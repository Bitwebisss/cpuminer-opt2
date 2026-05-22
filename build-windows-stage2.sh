#!/bin/bash
#
# build-windows-stage2.sh
# Called by build-windows-all.bat via MSYS2 UCRT64 bash.
# Can also be run manually inside MSYS2 UCRT64 terminal:
#
#   # Without GPU (CPU-only, all arch variants):
#   bash build-windows-stage2.sh --no-gpu
#
#   # With GPU (requires Stage 1 / libmm_gpu_gate.dll to exist first):
#   CPUMINER_GPU_GATE_WIN="C:/cpuminer-opt3/algo/argon2d/argon2-gpu/build_vs/Release" \
#   bash build-windows-stage2.sh
#
# Builds: SSE2, AES+SSE4.2, AVX, AVX2, AVX2+SHA, AVX2+SHA+VAES, AVX512, AVX512+SHA+VAES
# Output: cpuminer-windows-gpu.zip and/or cpuminer-windows-nogpu.zip in project root

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ============================================================
#  RESOLVE PROJECT DIR
# ============================================================
# When called from bat: $1 is the unix-style project path (/c/cpuminer-opt3)
# When called manually: auto-detect from script location
if [ -n "$1" ] && [ "$1" != "--no-gpu" ]; then
    PROJECT_DIR="$1"
else
    PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# GPU gate directory (set by bat via CPUMINER_GPU_GATE_WIN env var, or default)
if [ -n "$CPUMINER_GPU_GATE_WIN" ]; then
    GPU_GATE_DIR=$(cygpath -u "$CPUMINER_GPU_GATE_WIN")
else
    GPU_GATE_DIR="$PROJECT_DIR/algo/argon2d/argon2-gpu/build_vs/Release"
fi

NO_GPU=0
for arg in "$@"; do
    [ "$arg" = "--no-gpu" ] && NO_GPU=1
done

RELEASE_GPU="$PROJECT_DIR/release-windows/gpu"
RELEASE_NOGPU="$PROJECT_DIR/release-windows/nogpu"

DEFAULT_CFLAGS="-maes -O3 -Wall"
DEFAULT_CFLAGS_OLD="-O3 -Wall"

info "Project dir : $PROJECT_DIR"
info "GPU gate dir: $GPU_GATE_DIR"
info "No-GPU only : $NO_GPU"

# ============================================================
#  ENSURE UCRT64 TOOLCHAIN IN PATH
# ============================================================
export PATH="/ucrt64/bin:/usr/bin:$PATH"

# ============================================================
#  STATIC LINK ENVIRONMENT
# ============================================================
# LDFLAGS / CPPFLAGS are exported (not embedded in CONF_BASE string)
# so multi-word values survive word-split when ./configure $conf_args runs.
#
# WHY -static:
#   Avoids shipping ucrt64 runtime DLLs with every no-GPU build.
#   With -static, GCC prefers libXXX.a over libXXX.dll.a for every lib
#   that ships both. Windows system DLLs (kernel32, ntdll …) are always
#   dynamic because they have no .a counterpart — that is correct.
#
# WHY export LIBS (not just LDFLAGS):
#   configure.ac hardcodes LIBCURL="-lcurl -lz" (no transitive deps).
#   With -static the linker picks libcurl.a, which internally references
#   libssl, libcrypto, libbrotli*, libnghttp2, libzstd, libidn2 … none of
#   which appear in the link command → undefined reference → make fails.
#   LIBS is the standard autoconf variable for extra link libraries; anything
#   exported here gets written into the generated Makefile and appended to
#   every link command — exactly where the missing deps need to go.
#   pkg-config --static --libs resolves the full dependency graph.
export PKG_CONFIG_PATH="/ucrt64/lib/pkgconfig:/ucrt64/share/pkgconfig"
export LDFLAGS="-L/ucrt64/lib -static"
export CPPFLAGS="-I/ucrt64/include"
export LIBS
LIBS="$(pkg-config --static --libs libcurl openssl 2>/dev/null)" \
    || { warn "pkg-config --static failed; static link may have missing deps"; LIBS=""; }

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
#  VALIDATE GPU GATE (if GPU build requested)
# ============================================================
if [ "$NO_GPU" = "0" ]; then
    [ -f "$GPU_GATE_DIR/libmm_gpu_gate.dll" ]   || error "libmm_gpu_gate.dll not found in $GPU_GATE_DIR — run Stage 1 first"
    [ -f "$GPU_GATE_DIR/libmm_gpu_gate.dll.a" ] || error "libmm_gpu_gate.dll.a not found in $GPU_GATE_DIR — run Stage 1 first"
fi

# ============================================================
#  CONFIGURE ARGS
# ============================================================
CONF_BASE="--with-curl=/ucrt64 --host=x86_64-w64-mingw32"
CONF_GPU="--enable-gpu --with-mm-gpu-gate=$GPU_GATE_DIR $CONF_BASE"
CONF_NOGPU="$CONF_BASE"

# ============================================================
#  REGENERATE CONFIGURE
# ============================================================
cd "$PROJECT_DIR"
info "Running autogen.sh..."
./autogen.sh

# ============================================================
#  BUILD FUNCTION
# ============================================================
# Usage: build_variant "<cflags>" "<output_name>" "<conf_args>" "<out_dir>"
build_variant() {
    local cflags="$1"
    local name="$2"
    local conf_args="$3"
    local out_dir="$4"

    info "  Building $name..."
    make clean 2>/dev/null || true
    rm -f config.status
    export CFLAGS="$cflags"
    ./configure $conf_args 2>&1 | grep -E "(checking|error|warning)" | tail -5 || true
    make -j$(nproc) 2>&1 | tail -20
    strip -s cpuminer.exe || error "$name: cpuminer.exe not produced – check make output above"
    cp cpuminer.exe "$out_dir/$name"
    info "  → $name done"
}

# ============================================================
#  BUILD GPU VARIANTS
# ============================================================
if [ "$NO_GPU" = "0" ]; then
    info ""
    info "========================================"
    info "  Building GPU variants (8 CPU archs)"
    info "========================================"
    mkdir -p "$RELEASE_GPU"

    build_variant "-march=icelake-client $DEFAULT_CFLAGS"       "cpuminer-avx512-sha-vaes.exe" "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-march=skylake-avx512 $DEFAULT_CFLAGS"       "cpuminer-avx512.exe"          "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-mavx2 -msha -mvaes $DEFAULT_CFLAGS"         "cpuminer-avx2-sha-vaes.exe"   "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-march=znver1 $DEFAULT_CFLAGS"               "cpuminer-avx2-sha.exe"        "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-march=core-avx2 $DEFAULT_CFLAGS"            "cpuminer-avx2.exe"            "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD" "cpuminer-avx.exe"             "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-march=westmere -maes $DEFAULT_CFLAGS_OLD"   "cpuminer-aes-sse42.exe"       "$CONF_GPU" "$RELEASE_GPU"
    build_variant "-msse2 $DEFAULT_CFLAGS_OLD"                  "cpuminer-sse2.exe"            "$CONF_GPU" "$RELEASE_GPU"
fi

# ============================================================
#  BUILD NO-GPU VARIANTS
# ============================================================
info ""
info "========================================"
info "  Building no-GPU variants (8 CPU archs)"
info "========================================"
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
#  COPY RUNTIME DLLs  (GPU builds only)
# ============================================================
# No-GPU builds are fully static: every dependency (curl, ssl, gmp,
# jansson, pthreads …) is compiled into the .exe.  Nothing to copy.
#
# GPU builds dynamically load libmm_gpu_gate.dll (CUDA/OpenCL gate).
# That DLL and its transitive deps still need to ship alongside the exe.

copy_runtime_dlls() {
    local rel_dir="$1"
    local changed=1

    # Loop until no new DLLs are found — captures transitive dependencies.
    #
    # WHY objdump instead of ldd:
    #   ldd is an ELF tool; on MSYS2 it tries to simulate PE loading and often
    #   emits "??? (0x...)" instead of real paths for ucrt64 binaries — nothing
    #   gets copied.  objdump -p reads the PE import table directly from the
    #   file header: it always returns the exact DLL names the binary declares,
    #   independent of runtime path resolution.
    #
    # WHY checking /ucrt64/bin instead of filtering by pattern:
    #   System DLLs (kernel32, ntdll, ws2_32, bcrypt, …) are never in
    #   /ucrt64/bin, so the check acts as an automatic allow-list with zero
    #   false positives and no hard-coded skip list to maintain.
    while [ "$changed" = "1" ]; do
        changed=0

        local targets
        targets=$(find "$rel_dir" -maxdepth 1 \( -name "*.exe" -o -name "*.dll" \) 2>/dev/null)
        [ -z "$targets" ] && break

        # Read PE import tables → get every DLL name declared by every target
        local dll_names
        dll_names=$(objdump -p $targets 2>/dev/null \
            | grep -i "DLL Name:" \
            | awk '{print tolower($3)}' \
            | sort -u) || true
        [ -z "$dll_names" ] && break

        for dll_name in $dll_names; do
            # Find the actual file in ucrt64/bin (case-insensitive; NTFS is CI)
            local src
            src=$(find /ucrt64/bin -maxdepth 1 -iname "$dll_name" 2>/dev/null | head -1)
            [ -z "$src" ] && continue   # not a ucrt64 DLL → system DLL → skip

            local dest_name
            dest_name=$(basename "$src")
            if [ ! -f "$rel_dir/$dest_name" ]; then
                cp "$src" "$rel_dir/$dest_name"
                info "  Copied: $dest_name"
                changed=1
            fi
        done
    done
}

if [ "$NO_GPU" = "0" ]; then
    info ""
    info "Copying GPU runtime DLLs..."
    # Copy the GPU gate DLL first so copy_runtime_dlls also scans its imports
    cp "$GPU_GATE_DIR/libmm_gpu_gate.dll" "$RELEASE_GPU/"
    info "  Copied: libmm_gpu_gate.dll"
    copy_runtime_dlls "$RELEASE_GPU"
    mkdir -p "$RELEASE_GPU/data/kernels"
    cp "$PROJECT_DIR/algo/argon2d/argon2-gpu/data/kernels/argon2_kernel.cl" "$RELEASE_GPU/data/kernels/"
    info "  Copied: argon2_kernel.cl"
fi

# ============================================================
#  COPY DOCUMENTATION
# ============================================================
info "Copying documentation..."
for f in README.txt README.md RELEASE_NOTES verthash-help.txt; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        [ "$NO_GPU" = "0" ] && cp "$PROJECT_DIR/$f" "$RELEASE_GPU/"   || true
        cp "$PROJECT_DIR/$f" "$RELEASE_NOGPU/" || true
    fi
done

# ============================================================
#  HASHES
# ============================================================
info "Generating SHA-256 hashes..."
if [ "$NO_GPU" = "0" ]; then
    (cd "$RELEASE_GPU"   && sha256sum * 2>/dev/null > hashes.txt || true)
fi
(cd "$RELEASE_NOGPU" && sha256sum * 2>/dev/null > hashes.txt || true)

# ============================================================
#  PACK ZIPS
# ============================================================
info "Creating zip archives..."
cd "$PROJECT_DIR"

if [ "$NO_GPU" = "0" ]; then
    rm -f cpuminer-windows-gpu.zip
    zip -r cpuminer-windows-gpu.zip release-windows/gpu/
    info "  Created: cpuminer-windows-gpu.zip"
fi

rm -f cpuminer-windows-nogpu.zip
zip -r cpuminer-windows-nogpu.zip release-windows/nogpu/
info "  Created: cpuminer-windows-nogpu.zip"

# ============================================================
#  SUMMARY
# ============================================================
info ""
info "========================================"
info "  Stage 2 complete."
[ "$NO_GPU" = "0" ] && info "  GPU archive   : cpuminer-windows-gpu.zip"
info "  No-GPU archive: cpuminer-windows-nogpu.zip"
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

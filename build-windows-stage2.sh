#!/bin/bash
#
# build-windows-stage2.sh
# Fully static cpuminer.exe (except libmm_gpu_gate.dll) + automatic DLL copying via ldd
# QUICK_TEST mode: build only one variant but still perform full packaging
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# === QUICK TEST MODE ===
QUICK_TEST=0                 # Set to 1 to enable quick test
QUICK_VARIANT="cpuminer-sse2.exe"  # Exact executable name to build (e.g. cpuminer-sse2.exe)
# =========================

# Resolve project directory
if [ -n "$1" ] && [ "$1" != "--no-gpu" ]; then
    PROJECT_DIR="$1"
else
    PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# GPU gate directory
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
if [ "$QUICK_TEST" = "1" ]; then
    info "QUICK TEST MODE: will build only $QUICK_VARIANT and then package it"
fi

export PATH="/ucrt64/bin:/usr/bin:$PATH"

# Install required MSYS2 packages
info "Checking MSYS2 packages..."
REQUIRED_PKGS=(
    mingw-w64-ucrt-x86_64-gcc
    mingw-w64-ucrt-x86_64-curl
    mingw-w64-ucrt-x86_64-openssl
    mingw-w64-ucrt-x86_64-jansson
    mingw-w64-ucrt-x86_64-gmp
    mingw-w64-ucrt-x86_64-opencl-icd
    mingw-w64-ucrt-x86_64-opencl-headers
    autoconf automake libtool pkg-config zip
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

# Validate GPU gate
if [ "$NO_GPU" = "0" ]; then
    [ -f "$GPU_GATE_DIR/libmm_gpu_gate.dll" ]   || error "libmm_gpu_gate.dll not found"
    [ -f "$GPU_GATE_DIR/libmm_gpu_gate.dll.a" ] || error "libmm_gpu_gate.dll.a not found"
fi

# Configure arguments
CONF_BASE="--with-curl=/ucrt64 --host=x86_64-w64-mingw32"
CONF_GPU="--enable-gpu --with-mm-gpu-gate=$GPU_GATE_DIR $CONF_BASE"
CONF_NOGPU="$CONF_BASE"

export CPPFLAGS="-I/ucrt64/include"
export PKG_CONFIG_PATH="/ucrt64/lib/pkgconfig"
export LDFLAGS="-L/ucrt64/lib -static-libgcc -static-libstdc++"

STATIC_LIBS=$(pkg-config --static --libs libcurl openssl 2>/dev/null || echo "-lcurl -lssl -lcrypto -lz")
STATIC_LIBS_WRAPPED="-Wl,-Bstatic $STATIC_LIBS -Wl,-Bdynamic"

cd "$PROJECT_DIR"
info "Running autogen.sh..."
./autogen.sh

# Build function (returns 0 if built, 1 if skipped)
build_variant() {
    local cflags="$1"
    local name="$2"
    local conf_args="$3"
    local out_dir="$4"

    # Skip other variants in quick test mode
    if [ "$QUICK_TEST" = "1" ] && [ "$name" != "$QUICK_VARIANT" ]; then
        info "  Skipping $name (quick test mode)"
        return 1
    fi

    info "  Building $name..."
    make clean 2>/dev/null || true
    rm -f config.status
    export CFLAGS="$cflags -DCURL_STATICLIB"
    ./configure $conf_args LIBCURL="$STATIC_LIBS_WRAPPED" 2>&1 | grep -E "(checking|error|warning)" | tail -5 || true
    make -j$(nproc) 2>&1 | tail -3
    strip -s cpuminer.exe
    cp cpuminer.exe "$out_dir/$name"
    info "  → $name done"
    return 0
}

# Track which directories received built exe
BUILT_GPU=0
BUILT_NOGPU=0

# Build GPU variants
if [ "$NO_GPU" = "0" ]; then
    info ""
    info "========================================"
    info "  Building GPU variants (static + libmm_gpu_gate.dll)"
    info "========================================"
    mkdir -p "$RELEASE_GPU"

    for variant in \
        "-march=icelake-client $DEFAULT_CFLAGS       cpuminer-avx512-sha-vaes.exe" \
        "-march=skylake-avx512 $DEFAULT_CFLAGS       cpuminer-avx512.exe" \
        "-mavx2 -msha -mvaes $DEFAULT_CFLAGS         cpuminer-avx2-sha-vaes.exe" \
        "-march=znver1 $DEFAULT_CFLAGS               cpuminer-avx2-sha.exe" \
        "-march=core-avx2 $DEFAULT_CFLAGS            cpuminer-avx2.exe" \
        "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD cpuminer-avx.exe" \
        "-march=westmere -maes $DEFAULT_CFLAGS_OLD   cpuminer-aes-sse42.exe" \
        "-msse2 $DEFAULT_CFLAGS_OLD                  cpuminer-sse2.exe"
    do
        set -- $variant
        cflags="$1 $2 $3 $4"   # handle variable number of tokens
        name="${!#}"
        if build_variant "$cflags" "$name" "$CONF_GPU" "$RELEASE_GPU"; then
            BUILT_GPU=1
        fi
    done
fi

# Build no-GPU variants
info ""
info "========================================"
info "  Building no-GPU variants (fully static)"
info "========================================"
mkdir -p "$RELEASE_NOGPU"

for variant in \
    "-march=icelake-client $DEFAULT_CFLAGS       cpuminer-avx512-sha-vaes.exe" \
    "-march=skylake-avx512 $DEFAULT_CFLAGS       cpuminer-avx512.exe" \
    "-mavx2 -msha -mvaes $DEFAULT_CFLAGS         cpuminer-avx2-sha-vaes.exe" \
    "-march=znver1 $DEFAULT_CFLAGS               cpuminer-avx2-sha.exe" \
    "-march=core-avx2 $DEFAULT_CFLAGS            cpuminer-avx2.exe" \
    "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD cpuminer-avx.exe" \
    "-march=westmere -maes $DEFAULT_CFLAGS_OLD   cpuminer-aes-sse42.exe" \
    "-msse2 $DEFAULT_CFLAGS_OLD                  cpuminer-sse2.exe"
do
    set -- $variant
    cflags="$1 $2 $3 $4"
    name="${!#}"
    if build_variant "$cflags" "$name" "$CONF_NOGPU" "$RELEASE_NOGPU"; then
        BUILT_NOGPU=1
    fi
done

# Quick test: if no variant built (wrong name), exit with error
if [ "$QUICK_TEST" = "1" ] && [ "$BUILT_GPU" = "0" ] && [ "$BUILT_NOGPU" = "0" ]; then
    error "Quick test: variant '$QUICK_VARIANT' was not built. Check name."
fi

# ============================================================
#  POST-PROCESSING (only for non-empty release directories)
# ============================================================

# Copy runtime DLLs
info ""
info "Copying runtime DLLs..."

if [ "$NO_GPU" = "0" ] && [ "$BUILT_GPU" = "1" ]; then
    cp "$GPU_GATE_DIR/libmm_gpu_gate.dll" "$RELEASE_GPU/"
    info "  Copied: libmm_gpu_gate.dll"
    mkdir -p "$RELEASE_GPU/data/kernels"
    cp "$PROJECT_DIR/algo/argon2d/argon2-gpu/data/kernels/argon2_kernel.cl" "$RELEASE_GPU/data/kernels/"
    info "  Copied: argon2_kernel.cl"
    (cd "$RELEASE_GPU" && ldd cpuminer-sse2.exe libmm_gpu_gate.dll 2>/dev/null \
        | grep "ucrt64" \
        | awk '{print $3}' \
        | sort -u \
        | xargs -I{} cp {} .)
    info "  Runtime DLLs copied to $RELEASE_GPU"
fi

if [ "$BUILT_NOGPU" = "1" ]; then
    (cd "$RELEASE_NOGPU" && ldd cpuminer-sse2.exe 2>/dev/null \
        | grep "ucrt64" \
        | awk '{print $3}' \
        | sort -u \
        | xargs -I{} cp {} .)
    info "  Runtime DLLs copied to $RELEASE_NOGPU"
fi

# Copy documentation (only if directory has exe files)
info "Copying documentation..."
for f in README.txt README.md RELEASE_NOTES verthash-help.txt; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        [ "$NO_GPU" = "0" ] && [ "$BUILT_GPU" = "1" ] && cp "$PROJECT_DIR/$f" "$RELEASE_GPU/" 2>/dev/null || true
        [ "$BUILT_NOGPU" = "1" ] && cp "$PROJECT_DIR/$f" "$RELEASE_NOGPU/" 2>/dev/null || true
    fi
done

# Generate SHA-256 hashes
info "Generating SHA-256 hashes..."
if [ "$NO_GPU" = "0" ] && [ "$BUILT_GPU" = "1" ]; then
    (cd "$RELEASE_GPU" && sha256sum * 2>/dev/null > hashes.txt || true)
fi
if [ "$BUILT_NOGPU" = "1" ]; then
    (cd "$RELEASE_NOGPU" && sha256sum * 2>/dev/null > hashes.txt || true)
fi

# Create zip archives
info "Creating zip archives..."
cd "$PROJECT_DIR"
if [ "$NO_GPU" = "0" ] && [ "$BUILT_GPU" = "1" ]; then
    rm -f cpuminer-windows-gpu.zip
    zip -r cpuminer-windows-gpu.zip release-windows/gpu/
    info "  Created: cpuminer-windows-gpu.zip"
fi
if [ "$BUILT_NOGPU" = "1" ]; then
    rm -f cpuminer-windows-nogpu.zip
    zip -r cpuminer-windows-nogpu.zip release-windows/nogpu/
    info "  Created: cpuminer-windows-nogpu.zip"
fi

info ""
info "========================================"
info "  Stage 2 complete."
[ "$NO_GPU" = "0" ] && [ "$BUILT_GPU" = "1" ] && info "  GPU archive   : cpuminer-windows-gpu.zip"
[ "$BUILT_NOGPU" = "1" ] && info "  No-GPU archive: cpuminer-windows-nogpu.zip"
info "========================================"

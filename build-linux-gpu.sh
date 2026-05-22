#!/bin/bash
#
# build-linux-gpu.sh
# Builds cpuminer-opt3 on Linux with GPU support (CUDA + OpenCL) and
# all CPU architecture variants.
#
# STAGE 1: cmake builds libmm_gpu_gate.so (requires CUDA 11.8 + OpenCL)
# STAGE 2: autotools builds cpuminer for all 8 CPU arch variants (GPU + no-GPU)
#
# Tested on Ubuntu 20.04 / 22.04 with CUDA 11.8 and NVIDIA driver.
#
# Usage:
#   ./build-linux-gpu.sh             # Full build (GPU + no-GPU, 8 archs each)
#   ./build-linux-gpu.sh --no-gpu    # CPU-only all archs (skip Stage 1)
#   ./build-linux-gpu.sh --gpu-only  # GPU variants only (skip no-GPU builds)
#
# Output:
#   cpuminer-linux-x64-gpu.tar.gz    (with GPU support, 8 binaries + libmm_gpu_gate.so)
#   cpuminer-linux-x64-nogpu.tar.gz  (CPU only, 8 binaries)
#
# CPU arch variants (8, same as Windows):
#   avx512-sha-vaes  Intel Icelake/Rocketlake, AMD Zen4/Zen5
#   avx512           Intel Skylake-X, Cascadelake
#   avx2-sha-vaes    Intel Alderlake, AMD Zen3
#   avx2-sha         AMD Zen1 / Zen2
#   avx2             Intel Haswell to Cometlake
#   avx              Intel Sandybridge / Ivybridge
#   aes-sse42        Intel Westmere
#   sse2             Generic x64 fallback

set -e

# ============================================================
#  QUICK TEST MODE — set to 1 to build only one variant
#  (saves time when testing packaging / Stage 1 changes)
# ============================================================
QUICK_TEST=0
QUICK_VARIANT="cpuminer-sse2"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
found()   { echo -e "${CYAN}[FOUND]${NC} $*"; }
section() { echo -e "\n${BOLD}${GREEN}========================================${NC}"; \
            echo -e "${BOLD}${GREEN}  $*${NC}"; \
            echo -e "${BOLD}${GREEN}========================================${NC}"; }

# ============================================================
#  ARGS
# ============================================================
BUILD_GPU=1
BUILD_NOGPU=1
for arg in "$@"; do
    case "$arg" in
        --no-gpu)   BUILD_GPU=0   ;;
        --gpu-only) BUILD_NOGPU=0 ;;
    esac
done

# ============================================================
#  PATHS
# ============================================================
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU_SRC_DIR="$PROJECT_DIR/algo/argon2d/argon2-gpu"
GPU_BUILD_DIR="$GPU_SRC_DIR/build"
RELEASE_GPU="$PROJECT_DIR/release-linux/gpu"
RELEASE_NOGPU="$PROJECT_DIR/release-linux/nogpu"

DEFAULT_CFLAGS="-maes -O3 -Wall"
DEFAULT_CFLAGS_OLD="-O3 -Wall"

info "Project dir  : $PROJECT_DIR"
info "GPU build    : $BUILD_GPU"
info "No-GPU build : $BUILD_NOGPU"
[ "$QUICK_TEST" = "1" ] && info "QUICK TEST MODE: building only $QUICK_VARIANT"

# ============================================================
#  PREREQUISITES CHECK
# ============================================================
section "Checking prerequisites"

check_cmd() {
    local cmd="$1"
    local hint="$2"
    command -v "$cmd" &>/dev/null || error "$cmd not found. $hint"
}

check_cmd gcc         "sudo apt install build-essential"
check_cmd g++         "sudo apt install build-essential"
check_cmd make        "sudo apt install build-essential"
check_cmd cmake       "sudo apt install cmake"
check_cmd autoconf    "sudo apt install autoconf"
check_cmd automake    "sudo apt install automake"
check_cmd libtoolize  "sudo apt install libtool"
check_cmd pkg-config  "sudo apt install pkg-config"

if [ "$BUILD_GPU" = "1" ]; then
    check_cmd nvcc "Install CUDA 11.8: sudo sh cuda_11.8.0_520.61.05_linux.run --silent --toolkit --no-drm"
fi

# Check dev libraries (Debian/Ubuntu)
MISSING_LIBS=()
for lib in libcurl4-openssl-dev libjansson-dev libgmp-dev libssl-dev; do
    dpkg -s "$lib" &>/dev/null 2>&1 || MISSING_LIBS+=("$lib")
done
if [ "$BUILD_GPU" = "1" ]; then
    for lib in ocl-icd-opencl-dev opencl-headers; do
        dpkg -s "$lib" &>/dev/null 2>&1 || MISSING_LIBS+=("$lib")
    done
fi

if [ ${#MISSING_LIBS[@]} -gt 0 ]; then
    warn "Missing libraries: ${MISSING_LIBS[*]}"
    info "Installing missing libraries..."
    sudo apt update -qq
    sudo apt install -y "${MISSING_LIBS[@]}" || error "Failed to install libraries"
fi

info "Prerequisites OK"

# ============================================================
#  STAGE 1: Build libmm_gpu_gate.so
# ============================================================
if [ "$BUILD_GPU" = "1" ]; then
    section "STAGE 1: Building libmm_gpu_gate.so"

    # Detect CUDA root
    CUDA_ROOT="${CUDA_PATH:-${CUDA_TOOLKIT_ROOT_DIR:-/usr/local/cuda-11.8}}"
    if [ ! -f "$CUDA_ROOT/bin/nvcc" ]; then
        for d in /usr/local/cuda /usr/local/cuda-11.8 /usr/local/cuda-11; do
            [ -f "$d/bin/nvcc" ] && CUDA_ROOT="$d" && break
        done
    fi
    [ -f "$CUDA_ROOT/bin/nvcc" ] || error "nvcc not found. Set CUDA_PATH env var or install CUDA 11.8."
    info "CUDA root: $CUDA_ROOT"

    # Detect OpenCL library (ICD loader)
    OPENCL_LIB=""
    for candidate in \
        /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 \
        /usr/lib/x86_64-linux-gnu/libOpenCL.so \
        /usr/lib/libOpenCL.so; do
        [ -f "$candidate" ] && OPENCL_LIB="$candidate" && break
    done
    [ -z "$OPENCL_LIB" ] && OPENCL_LIB=$(find /usr/lib -name "libOpenCL.so*" 2>/dev/null | head -1)
    [ -n "$OPENCL_LIB" ] || error "libOpenCL.so not found. Install: sudo apt install ocl-icd-opencl-dev"
    info "OpenCL lib: $OPENCL_LIB"

    [ -f "$GPU_SRC_DIR/CMakeLists.txt" ] || error "argon2-gpu CMakeLists.txt not found. Run: git submodule update --init --recursive"

    rm -rf "$GPU_BUILD_DIR"
    mkdir -p "$GPU_BUILD_DIR"
    cd "$GPU_BUILD_DIR"

    cmake "$GPU_SRC_DIR" \
        -DNO_CUDA=FALSE \
        -DCMAKE_BUILD_TYPE=Release \
        -DOpenCL_LIBRARY="$OPENCL_LIB" \
        -DOpenCL_INCLUDE_DIR=/usr/include

    make -j$(nproc)

    [ -f "$GPU_BUILD_DIR/libmm_gpu_gate.so" ] || error "libmm_gpu_gate.so was not produced"
    info "Stage 1 OK: $GPU_BUILD_DIR/libmm_gpu_gate.so"
fi

# ============================================================
#  VALIDATE GPU FILES BEFORE STARTING ANY BUILDS
#  (same fail-fast logic as Windows stage2 — catch errors early,
#  not after 30 minutes of compiling)
# ============================================================
if [ "$BUILD_GPU" = "1" ]; then
    [ -f "$GPU_BUILD_DIR/libmm_gpu_gate.so" ] \
        || error "libmm_gpu_gate.so not found in $GPU_BUILD_DIR — run Stage 1 first (or without --gpu-only)"
    [ -f "$GPU_SRC_DIR/data/kernels/argon2_kernel.cl" ] \
        || error "argon2_kernel.cl not found — check your source tree"
fi

# ============================================================
#  STAGE 2: Build cpuminer variants
# ============================================================
section "STAGE 2: Building cpuminer variants"

cd "$PROJECT_DIR"
info "Running autogen.sh..."
./autogen.sh

mkdir -p "$RELEASE_GPU" "$RELEASE_NOGPU"

# rpath='$ORIGIN' — binary finds libmm_gpu_gate.so in the same directory as itself.
# This makes the GPU binaries work without LD_LIBRARY_PATH (run-gpu.sh stays as backup).
# Note: single quotes preserve the literal $ORIGIN for the ELF loader.
RPATH_FLAGS='-Wl,-rpath,$ORIGIN'

CONF_GPU_ARGS="--enable-gpu --with-mm-gpu-gate=$GPU_BUILD_DIR --with-curl LDFLAGS=$RPATH_FLAGS"
CONF_NOGPU_ARGS="--with-curl"

# ============================================================
#  verify_and_copy_gpu_files  OUT_DIR
#
#  Called after EVERY GPU binary build (fail-fast, same as Windows).
#  libmm_gpu_gate.so and the OpenCL kernel are GPU-specific files that
#  ldd will not find — they are checked and copied explicitly here.
# ============================================================
verify_and_copy_gpu_files() {
    local out_dir="$1"

    # libmm_gpu_gate.so
    if [ -f "$out_dir/libmm_gpu_gate.so" ]; then
        found "    libmm_gpu_gate.so — SKIP COPY"
    else
        cp "$GPU_BUILD_DIR/libmm_gpu_gate.so" "$out_dir/" \
            || error "Copy failed: libmm_gpu_gate.so → $out_dir/ — cannot continue"
        info "    Copied: libmm_gpu_gate.so"
    fi

    # argon2_kernel.cl
    local kernel_dst="$out_dir/data/kernels"
    mkdir -p "$kernel_dst"
    if [ -f "$kernel_dst/argon2_kernel.cl" ]; then
        found "    argon2_kernel.cl — SKIP COPY"
    else
        cp "$GPU_SRC_DIR/data/kernels/argon2_kernel.cl" "$kernel_dst/" \
            || error "Copy failed: argon2_kernel.cl → $kernel_dst/ — cannot continue"
        info "    Copied: data/kernels/argon2_kernel.cl"
    fi
}

# ============================================================
#  build_variant  CFLAGS  NAME  CONF_ARGS  OUT_DIR  [gpu]
#
#  1. Build the binary
#  2. If "gpu": immediately verify + copy GPU-specific files — stop on first failure
#  3. Only then return — next variant can start
# ============================================================
build_variant() {
    local cflags="$1"
    local name="$2"
    local conf_args="$3"
    local out_dir="$4"
    local extra="${5:-}"

    if [ "$QUICK_TEST" = "1" ] && [ "$name" != "$QUICK_VARIANT" ]; then
        info "  Skipping $name (quick test mode)"
        return 0
    fi

    info ""
    info "  ── Building $name ──"
    make clean 2>/dev/null || true
    rm -f config.status
    export CFLAGS="$cflags"
    ./configure $conf_args 2>&1 | grep -E "(configure: error|error:)" | head -5 || true
    make -j$(nproc) 2>&1 | tail -3
    strip -s cpuminer
    cp cpuminer "$out_dir/$name"
    info "  ✓ $name compiled"

    if [ "$extra" = "gpu" ]; then
        info "  Verifying GPU-specific files for $name..."
        verify_and_copy_gpu_files "$out_dir"
        info "  ✓ $name — GPU files OK"
    fi
}

# ============================================================
#  GPU VARIANTS  (8 CPU archs, same as Windows)
# ============================================================
if [ "$BUILD_GPU" = "1" ]; then
    info ""
    info "========================================"
    info "  Building GPU variants (8 CPU archs)"
    info "========================================"

    build_variant "-march=icelake-client $DEFAULT_CFLAGS"       "cpuminer-avx512-sha-vaes" "$CONF_GPU_ARGS" "$RELEASE_GPU" "gpu"
    build_variant "-march=skylake-avx512 $DEFAULT_CFLAGS"       "cpuminer-avx512"          "$CONF_GPU_ARGS" "$RELEASE_GPU" "gpu"
    build_variant "-mavx2 -msha -mvaes $DEFAULT_CFLAGS"         "cpuminer-avx2-sha-vaes"   "$CONF_GPU_ARGS" "$RELEASE_GPU" "gpu"
    build_variant "-march=znver1 $DEFAULT_CFLAGS"               "cpuminer-avx2-sha"        "$CONF_GPU_ARGS" "$RELEASE_GPU" "gpu"
    build_variant "-march=core-avx2 $DEFAULT_CFLAGS"            "cpuminer-avx2"            "$CONF_GPU_ARGS" "$RELEASE_GPU" "gpu"
    build_variant "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD" "cpuminer-avx"             "$CONF_GPU_ARGS" "$RELEASE_GPU" "gpu"
    build_variant "-march=westmere -maes $DEFAULT_CFLAGS_OLD"   "cpuminer-aes-sse42"       "$CONF_GPU_ARGS" "$RELEASE_GPU" "gpu"
    build_variant "-msse2 $DEFAULT_CFLAGS_OLD"                  "cpuminer-sse2"            "$CONF_GPU_ARGS" "$RELEASE_GPU" "gpu"
fi

# ============================================================
#  NO-GPU VARIANTS  (8 CPU archs, same as Windows)
# ============================================================
if [ "$BUILD_NOGPU" = "1" ]; then
    info ""
    info "========================================"
    info "  Building no-GPU variants (8 CPU archs)"
    info "========================================"

    build_variant "-march=icelake-client $DEFAULT_CFLAGS"       "cpuminer-avx512-sha-vaes" "$CONF_NOGPU_ARGS" "$RELEASE_NOGPU"
    build_variant "-march=skylake-avx512 $DEFAULT_CFLAGS"       "cpuminer-avx512"          "$CONF_NOGPU_ARGS" "$RELEASE_NOGPU"
    build_variant "-mavx2 -msha -mvaes $DEFAULT_CFLAGS"         "cpuminer-avx2-sha-vaes"   "$CONF_NOGPU_ARGS" "$RELEASE_NOGPU"
    build_variant "-march=znver1 $DEFAULT_CFLAGS"               "cpuminer-avx2-sha"        "$CONF_NOGPU_ARGS" "$RELEASE_NOGPU"
    build_variant "-march=core-avx2 $DEFAULT_CFLAGS"            "cpuminer-avx2"            "$CONF_NOGPU_ARGS" "$RELEASE_NOGPU"
    build_variant "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD" "cpuminer-avx"             "$CONF_NOGPU_ARGS" "$RELEASE_NOGPU"
    build_variant "-march=westmere -maes $DEFAULT_CFLAGS_OLD"   "cpuminer-aes-sse42"       "$CONF_NOGPU_ARGS" "$RELEASE_NOGPU"
    build_variant "-msse2 $DEFAULT_CFLAGS_OLD"                  "cpuminer-sse2"            "$CONF_NOGPU_ARGS" "$RELEASE_NOGPU"
fi

# ============================================================
#  DOCUMENTATION
# ============================================================
info "Copying documentation..."
for f in README.txt README.md RELEASE_NOTES; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        [ "$BUILD_GPU" = "1" ]   && cp "$PROJECT_DIR/$f" "$RELEASE_GPU/"   || true
        [ "$BUILD_NOGPU" = "1" ] && cp "$PROJECT_DIR/$f" "$RELEASE_NOGPU/" || true
    fi
done

# ============================================================
#  PACKAGE GPU RELEASE
# ============================================================
if [ "$BUILD_GPU" = "1" ]; then
    section "Packaging GPU release"

    # Auto-selector launcher.
    # run-gpu.sh is a backup for edge cases (noexec mount, stripped rpath).
    # Normally the rpath=$ORIGIN baked into each binary makes it work without this.
    #
    # Selector logic uses /proc/cpuinfo flags directly (whole-word match):
    #   avx512f + sha_ni + vaes → avx512-sha-vaes (Icelake / Zen4 / Zen5)
    #   avx512f                 → avx512           (Skylake-X / Cascadelake)
    #   avx2 + sha_ni + vaes    → avx2-sha-vaes    (Alderlake / Zen3)
    #   avx2 + sha_ni           → avx2-sha         (Zen1 / Zen2)
    #   avx2                    → avx2
    #   avx                     → avx
    #   aes + sse4_2            → aes-sse42
    #   fallback                → sse2
    cat > "$RELEASE_GPU/run-gpu.sh" << 'LAUNCHER'
#!/bin/bash
# GPU launcher: sets LD_LIBRARY_PATH (backup for noexec mounts / stripped rpath)
# and auto-selects the best binary for this CPU.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$DIR:$LD_LIBRARY_PATH"

FLAGS=$(grep -m1 "^flags" /proc/cpuinfo 2>/dev/null)
has() { echo "$FLAGS" | grep -qw "$1"; }

if has avx512f && has sha_ni && has vaes; then
    BIN="$DIR/cpuminer-avx512-sha-vaes"
elif has avx512f; then
    BIN="$DIR/cpuminer-avx512"
elif has avx2 && has sha_ni && has vaes; then
    BIN="$DIR/cpuminer-avx2-sha-vaes"
elif has avx2 && has sha_ni; then
    BIN="$DIR/cpuminer-avx2-sha"
elif has avx2; then
    BIN="$DIR/cpuminer-avx2"
elif has avx; then
    BIN="$DIR/cpuminer-avx"
elif has aes && has sse4_2; then
    BIN="$DIR/cpuminer-aes-sse42"
else
    BIN="$DIR/cpuminer-sse2"
fi

echo "Using: $BIN"
exec "$BIN" "$@"
LAUNCHER
    chmod +x "$RELEASE_GPU/run-gpu.sh"
    info "  Created: run-gpu.sh"

    # Hashes (only files, not directories)
    (cd "$RELEASE_GPU" && sha256sum cpuminer-* libmm_gpu_gate.so 2>/dev/null > hashes.txt || true)
    info "  Created: hashes.txt"

    # Archive — files at root, same as Windows zip behaviour
    rm -f "$PROJECT_DIR/cpuminer-linux-x64-gpu.tar.gz"
    tar czf "$PROJECT_DIR/cpuminer-linux-x64-gpu.tar.gz" -C "$RELEASE_GPU" .
    info "  Created: cpuminer-linux-x64-gpu.tar.gz"
fi

# ============================================================
#  PACKAGE NO-GPU RELEASE
# ============================================================
if [ "$BUILD_NOGPU" = "1" ]; then
    section "Packaging no-GPU release"

    cat > "$RELEASE_NOGPU/run.sh" << 'LAUNCHER'
#!/bin/bash
# Auto-selects the best cpuminer binary for this CPU.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FLAGS=$(grep -m1 "^flags" /proc/cpuinfo 2>/dev/null)
has() { echo "$FLAGS" | grep -qw "$1"; }

if has avx512f && has sha_ni && has vaes; then
    BIN="$DIR/cpuminer-avx512-sha-vaes"
elif has avx512f; then
    BIN="$DIR/cpuminer-avx512"
elif has avx2 && has sha_ni && has vaes; then
    BIN="$DIR/cpuminer-avx2-sha-vaes"
elif has avx2 && has sha_ni; then
    BIN="$DIR/cpuminer-avx2-sha"
elif has avx2; then
    BIN="$DIR/cpuminer-avx2"
elif has avx; then
    BIN="$DIR/cpuminer-avx"
elif has aes && has sse4_2; then
    BIN="$DIR/cpuminer-aes-sse42"
else
    BIN="$DIR/cpuminer-sse2"
fi

echo "Using: $BIN"
exec "$BIN" "$@"
LAUNCHER
    chmod +x "$RELEASE_NOGPU/run.sh"
    info "  Created: run.sh"

    (cd "$RELEASE_NOGPU" && sha256sum cpuminer-* 2>/dev/null > hashes.txt || true)
    info "  Created: hashes.txt"

    rm -f "$PROJECT_DIR/cpuminer-linux-x64-nogpu.tar.gz"
    tar czf "$PROJECT_DIR/cpuminer-linux-x64-nogpu.tar.gz" -C "$RELEASE_NOGPU" .
    info "  Created: cpuminer-linux-x64-nogpu.tar.gz"
fi

# ============================================================
#  SUMMARY
# ============================================================
section "BUILD COMPLETE"
echo ""
[ "$BUILD_GPU" = "1" ]   && echo "  GPU archive:    cpuminer-linux-x64-gpu.tar.gz"
[ "$BUILD_NOGPU" = "1" ] && echo "  No-GPU archive: cpuminer-linux-x64-nogpu.tar.gz"
echo ""
echo "  CPU arch variants (8, mirrors Windows):"
echo "    avx512-sha-vaes  Intel Icelake/Rocketlake, AMD Zen4/Zen5"
echo "    avx512           Intel Skylake-X, Cascadelake"
echo "    avx2-sha-vaes    Intel Alderlake, AMD Zen3"
echo "    avx2-sha         AMD Zen1 / Zen2"
echo "    avx2             Intel Haswell to Cometlake"
echo "    avx              Intel Sandybridge / Ivybridge"
echo "    aes-sse42        Intel Westmere"
echo "    sse2             Generic x64 fallback"
echo ""
if [ "$BUILD_GPU" = "1" ]; then
    echo "  GPU usage (rpath baked in, no LD_LIBRARY_PATH needed):"
    echo "    cd release-linux/gpu"
    echo "    ./cpuminer-avx2-sha-vaes --algo argon2id1024 --use-gpu CUDA \\"
    echo "      --url stratum+tcp://pool:port --user wallet.worker --pass x"
    echo ""
    echo "  Or use the auto-selector:"
    echo "    ./run-gpu.sh --algo argon2id1024 --use-gpu CUDA --url ..."
fi
echo ""

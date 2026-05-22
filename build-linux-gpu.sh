#!/bin/bash
#
# build-linux-gpu.sh
# Builds cpuminer-opt3 on Linux with GPU support (CUDA + OpenCL) and
# all CPU architecture variants.
#
# STAGE 1: cmake builds libmm_gpu_gate.so (requires CUDA 11.8 + OpenCL)
# STAGE 2: autotools builds cpuminer for all CPU archs (GPU + no-GPU)
#
# Tested on Ubuntu 20.04 / 22.04 with CUDA 11.8 and NVIDIA driver.
#
# Usage:
#   ./build-linux-gpu.sh             # Full build (GPU + no-GPU all archs)
#   ./build-linux-gpu.sh --no-gpu    # CPU-only all archs (skip Stage 1)
#   ./build-linux-gpu.sh --gpu-only  # GPU variants only (skip no-GPU builds)
#
# Output:
#   cpuminer-linux-x64-gpu.tar.gz    (with GPU support)
#   cpuminer-linux-x64-nogpu.tar.gz  (CPU only)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${GREEN}========================================${NC}"; echo -e "${BOLD}${GREEN}  $*${NC}"; echo -e "${BOLD}${GREEN}========================================${NC}"; }

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

info "Project: $PROJECT_DIR"
info "GPU build:   $BUILD_GPU"
info "No-GPU build: $BUILD_NOGPU"

# ============================================================
#  PREREQUISITES CHECK
# ============================================================
section "Checking prerequisites"

check_cmd() {
    local cmd="$1"
    local hint="$2"
    command -v "$cmd" &>/dev/null || error "$cmd not found. $hint"
}

check_cmd gcc    "sudo apt install build-essential"
check_cmd g++    "sudo apt install build-essential"
check_cmd make   "sudo apt install build-essential"
check_cmd cmake  "sudo apt install cmake"
check_cmd autoconf "sudo apt install autoconf"
check_cmd automake "sudo apt install automake"
check_cmd libtoolize "sudo apt install libtool"
check_cmd pkg-config "sudo apt install pkg-config"

if [ "$BUILD_GPU" = "1" ]; then
    check_cmd nvcc "Install CUDA 11.8: sudo sh cuda_11.8.0_520.61.05_linux.run --silent --toolkit --no-drm"
fi

# Check libraries
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
        # Try common alternatives
        for d in /usr/local/cuda /usr/local/cuda-11.8 /usr/local/cuda-11; do
            [ -f "$d/bin/nvcc" ] && CUDA_ROOT="$d" && break
        done
    fi
    [ -f "$CUDA_ROOT/bin/nvcc" ] || error "nvcc not found. Set CUDA_PATH env var or install CUDA 11.8."
    info "CUDA root: $CUDA_ROOT"

    # Detect OpenCL library
    OPENCL_LIB=""
    for candidate in \
        /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 \
        /usr/lib/x86_64-linux-gnu/libOpenCL.so \
        /usr/lib/libOpenCL.so; do
        [ -f "$candidate" ] && OPENCL_LIB="$candidate" && break
    done
    # Also search
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
#  STAGE 2: Build cpuminer variants
# ============================================================
section "STAGE 2: Building cpuminer variants"

cd "$PROJECT_DIR"
info "Running autogen.sh..."
./autogen.sh

CONF_GPU_ARGS="--enable-gpu --with-mm-gpu-gate=$GPU_BUILD_DIR --with-curl"
CONF_NOGPU_ARGS="--with-curl"

mkdir -p "$RELEASE_GPU" "$RELEASE_NOGPU"

# ---- build_variant <cflags> <output_name> <configure_args> <out_dir> ----
build_variant() {
    local cflags="$1"
    local name="$2"
    local conf_args="$3"
    local out_dir="$4"

    info "  Building: $name"
    make clean 2>/dev/null || true
    rm -f config.status
    export CFLAGS="$cflags"
    # Show last few lines of configure and make
    ./configure $conf_args 2>&1 | grep -E "^(checking for|configure: error|warning)" | tail -3 || true
    make -j$(nproc) 2>&1 | tail -3
    strip -s cpuminer
    cp cpuminer "$out_dir/$name"
    info "  ✓ $name"
}

# CPU architecture definitions
# Format: "CFLAGS_suffix|output_name_suffix"
declare -a ARCH_CFLAGS=(
    "-march=znver5 $DEFAULT_CFLAGS|cpuminer-zen5"
    "-march=znver4 $DEFAULT_CFLAGS|cpuminer-zen4"
    "-march=znver3 $DEFAULT_CFLAGS|cpuminer-zen3"
    "-march=icelake-client $DEFAULT_CFLAGS|cpuminer-avx512-sha-vaes"
    "-march=skylake-avx512 $DEFAULT_CFLAGS|cpuminer-avx512"
    "-mavx2 -msha -mvaes $DEFAULT_CFLAGS|cpuminer-avx2-sha-vaes"
    "-march=znver1 $DEFAULT_CFLAGS|cpuminer-avx2-sha"
    "-march=core-avx2 -maes $DEFAULT_CFLAGS|cpuminer-avx2"
    "-march=corei7-avx -maes $DEFAULT_CFLAGS_OLD|cpuminer-avx"
    "-march=westmere -maes $DEFAULT_CFLAGS_OLD|cpuminer-aes-sse42"
    "-march=corei7 $DEFAULT_CFLAGS_OLD|cpuminer-sse42"
    "-march=x86-64 -msse2 $DEFAULT_CFLAGS_OLD|cpuminer-sse2"
)

# Build GPU variants
if [ "$BUILD_GPU" = "1" ]; then
    info ""
    info "--- GPU variants (${#ARCH_CFLAGS[@]} CPU archs) ---"
    for entry in "${ARCH_CFLAGS[@]}"; do
        IFS='|' read -r cflags name <<< "$entry"
        build_variant "$cflags" "$name" "$CONF_GPU_ARGS" "$RELEASE_GPU"
    done
fi

# Build no-GPU variants
if [ "$BUILD_NOGPU" = "1" ]; then
    info ""
    info "--- No-GPU variants (${#ARCH_CFLAGS[@]} CPU archs) ---"
    for entry in "${ARCH_CFLAGS[@]}"; do
        IFS='|' read -r cflags name <<< "$entry"
        build_variant "$cflags" "$name" "$CONF_NOGPU_ARGS" "$RELEASE_NOGPU"
    done
fi

# ============================================================
#  PACKAGE GPU RELEASE
# ============================================================
if [ "$BUILD_GPU" = "1" ]; then
    section "Packaging GPU release"

    # Copy the shared library into release dir
    cp "$GPU_BUILD_DIR/libmm_gpu_gate.so" "$RELEASE_GPU/"
    info "  Copied: libmm_gpu_gate.so"

    # OpenCL kernel
    mkdir -p "$RELEASE_GPU/data/kernels"
    cp "$GPU_SRC_DIR/data/kernels/argon2_kernel.cl" "$RELEASE_GPU/data/kernels/"
    info "  Copied: argon2_kernel.cl"

    # Create a launcher wrapper that sets LD_LIBRARY_PATH automatically
    cat > "$RELEASE_GPU/run-gpu.sh" << 'LAUNCHER'
#!/bin/bash
# Launcher wrapper: sets LD_LIBRARY_PATH so libmm_gpu_gate.so is found at runtime.
# Place this file in the same directory as the cpuminer binary and the .so file.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$DIR:$LD_LIBRARY_PATH"

# Auto-select best binary for this CPU
if grep -q avx512 /proc/cpuinfo 2>/dev/null && grep -q sha_ni /proc/cpuinfo 2>/dev/null; then
    BIN="$DIR/cpuminer-avx512-sha-vaes"
elif grep -q avx512 /proc/cpuinfo 2>/dev/null; then
    BIN="$DIR/cpuminer-avx512"
elif grep -q avx2 /proc/cpuinfo 2>/dev/null && grep -q sha_ni /proc/cpuinfo 2>/dev/null; then
    BIN="$DIR/cpuminer-avx2-sha-vaes"
elif grep -q avx2 /proc/cpuinfo 2>/dev/null; then
    BIN="$DIR/cpuminer-avx2"
elif grep -q avx /proc/cpuinfo 2>/dev/null; then
    BIN="$DIR/cpuminer-avx"
else
    BIN="$DIR/cpuminer-sse2"
fi

echo "Using: $BIN"
exec "$BIN" "$@"
LAUNCHER
    chmod +x "$RELEASE_GPU/run-gpu.sh"
    info "  Created: run-gpu.sh (auto-selects binary + sets LD_LIBRARY_PATH)"

    # Copy docs
    for f in README.txt README.md RELEASE_NOTES; do
        [ -f "$PROJECT_DIR/$f" ] && cp "$PROJECT_DIR/$f" "$RELEASE_GPU/" || true
    done

    # Hashes
    (cd "$RELEASE_GPU" && sha256sum * 2>/dev/null > hashes.txt || true)

    # Archive
    rm -f "$PROJECT_DIR/cpuminer-linux-x64-gpu.tar.gz"
    tar czf "$PROJECT_DIR/cpuminer-linux-x64-gpu.tar.gz" -C "$PROJECT_DIR" release-linux/gpu/
    info "  Created: cpuminer-linux-x64-gpu.tar.gz"
fi

# ============================================================
#  PACKAGE NO-GPU RELEASE
# ============================================================
if [ "$BUILD_NOGPU" = "1" ]; then
    section "Packaging no-GPU release"

    # Auto-selector script (no LD_LIBRARY_PATH needed)
    cat > "$RELEASE_NOGPU/run.sh" << 'LAUNCHER'
#!/bin/bash
# Auto-selects the best cpuminer binary for this CPU.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if grep -q avx512 /proc/cpuinfo 2>/dev/null && grep -q sha_ni /proc/cpuinfo 2>/dev/null; then
    BIN="$DIR/cpuminer-avx512-sha-vaes"
elif grep -q avx512 /proc/cpuinfo 2>/dev/null; then
    BIN="$DIR/cpuminer-avx512"
elif grep -q avx2 /proc/cpuinfo 2>/dev/null && grep -q sha_ni /proc/cpuinfo 2>/dev/null; then
    BIN="$DIR/cpuminer-avx2-sha-vaes"
elif grep -q avx2 /proc/cpuinfo 2>/dev/null; then
    BIN="$DIR/cpuminer-avx2"
elif grep -q avx /proc/cpuinfo 2>/dev/null; then
    BIN="$DIR/cpuminer-avx"
else
    BIN="$DIR/cpuminer-sse2"
fi

echo "Using: $BIN"
exec "$BIN" "$@"
LAUNCHER
    chmod +x "$RELEASE_NOGPU/run.sh"
    info "  Created: run.sh"

    for f in README.txt README.md RELEASE_NOTES; do
        [ -f "$PROJECT_DIR/$f" ] && cp "$PROJECT_DIR/$f" "$RELEASE_NOGPU/" || true
    done

    (cd "$RELEASE_NOGPU" && sha256sum * 2>/dev/null > hashes.txt || true)

    rm -f "$PROJECT_DIR/cpuminer-linux-x64-nogpu.tar.gz"
    tar czf "$PROJECT_DIR/cpuminer-linux-x64-nogpu.tar.gz" -C "$PROJECT_DIR" release-linux/nogpu/
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
echo "  Built CPU arch variants:"
echo "    zen5             AMD Zen5 (AVX512 SHA VAES)      - requires gcc-14"
echo "    zen4             AMD Zen4 (AVX512 SHA VAES)      - requires gcc-12"
echo "    zen3             AMD Zen3 (AVX2 SHA VAES)"
echo "    avx512-sha-vaes  Intel Icelake / Rocketlake"
echo "    avx512           Intel Skylake-X / Cascadelake"
echo "    avx2-sha-vaes    Intel Alderlake / AMD Zen3+"
echo "    avx2-sha         AMD Zen1 / Zen2"
echo "    avx2             Intel Haswell to Cometlake"
echo "    avx              Intel Sandybridge / Ivybridge"
echo "    aes-sse42        Intel Westmere"
echo "    sse42            Intel Nehalem (no AES)"
echo "    sse2             Generic x64 fallback"
echo ""
if [ "$BUILD_GPU" = "1" ]; then
    echo "  GPU usage example:"
    echo "    cd release-linux/gpu"
    echo "    LD_LIBRARY_PATH=. ./cpuminer-avx2-sha-vaes \\"
    echo "      --algo argon2id1024 --use-gpu CUDA \\"
    echo "      --url stratum+tcp://pool:port --user wallet.worker --pass x"
    echo "    # Or use the auto-selector wrapper:"
    echo "    ./run-gpu.sh --algo argon2id1024 --use-gpu CUDA --url ..."
fi
echo ""

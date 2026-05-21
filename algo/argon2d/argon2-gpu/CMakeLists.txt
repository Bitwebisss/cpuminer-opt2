cmake_minimum_required(VERSION 3.5)

project(argon2-gpu CXX)
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ============================================================
#  OpenCL
# ============================================================
find_package(OpenCL)

# ============================================================
#  CUDA — legacy FindCUDA (works with VS 2019 + CUDA 11.8)
# ============================================================
set(CUDA_FOUND FALSE)
if(NOT NO_CUDA)
    find_package(CUDA)
endif()

if(CUDA_FOUND)
    message(STATUS "Using CUDA version ${CUDA_VERSION}")
    add_definitions(-DHAVE_CUDA=1)

    set(ARGON2_CUDA_GENCODE
        -gencode arch=compute_61,code=sm_61
        -gencode arch=compute_75,code=sm_75
        -gencode arch=compute_80,code=sm_80
        -gencode arch=compute_86,code=sm_86
        -gencode arch=compute_86,code=compute_86
    )

    if(MSVC OR WIN32)
        set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS}
            -std=c++17 -O3 --ptxas-options=-v -lineinfo
            # suppress nvcc #177-D: variable declared but never referenced (tzflag in kernels.cu:1327)
            # appears 4x because nvcc compiles once per architecture (sm_61/75/80/86)
            --diag-suppress=177
            ${ARGON2_CUDA_GENCODE}
        )
    else()
        set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS}
            -std=c++17 --compiler-options=-fPIC -O3 --ptxas-options=-v -lineinfo
            --diag-suppress=177
            ${ARGON2_CUDA_GENCODE}
        )
    endif()
else()
    message(STATUS "Building without CUDA support")
    add_definitions(-DHAVE_CUDA=0)
endif()

# ============================================================
#  MSVC warning suppression flags (third-party code, not ours)
#  C4267 = size_t -> uint32_t/int (all targets, all headers)
#  C4101 = unused local variable (ex in processingunit, err in kernelloader)
# ============================================================
if(MSVC)
    set(ARGON2_MSVC_WARN /wd4267 /wd4101)
else()
    set(ARGON2_MSVC_WARN "")
endif()

# ============================================================
#  Static helper libraries
# ============================================================
add_library(argon2-gpu-common STATIC
    lib/argon2-gpu-common/argon2params.cpp
    lib/argon2-gpu-common/blake2b.cpp
)
target_include_directories(argon2-gpu-common INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)
target_include_directories(argon2-gpu-common PRIVATE
    include/argon2-gpu-common
    lib/argon2-gpu-common
)
# C4267: argon2params.cpp:32,35,94,121,123 — size_t -> uint32_t
target_compile_options(argon2-gpu-common PRIVATE ${ARGON2_MSVC_WARN})
include_directories(include)

# ============================================================
#  CUDA backend
# ============================================================
if(CUDA_FOUND)
    cuda_add_library(argon2-cuda STATIC
        lib/argon2-cuda/device.cpp
        lib/argon2-cuda/globalcontext.cpp
        lib/argon2-cuda/programcontext.cpp
        lib/argon2-cuda/processingunit.cpp
        lib/argon2-cuda/kernels.cu
    )
    include_directories(${CUDA_INCLUDE_DIRS})
else()
    add_library(argon2-cuda STATIC
        lib/argon2-cuda/nocuda.cpp
    )
endif()

target_include_directories(argon2-cuda INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)
target_include_directories(argon2-cuda PRIVATE
    include/argon2-cuda
    lib/argon2-cuda
)
# C4267: kernels.h:60, kernels.cu:1135,1220,1285,1290, processingunit.cpp:135,144,159 — size_t -> uint32_t/unsigned int
# C4101: processingunit.cpp:67,107 — unused local variable 'ex'
target_compile_options(argon2-cuda PRIVATE ${ARGON2_MSVC_WARN})
target_link_libraries(argon2-cuda argon2-gpu-common)

# ============================================================
#  OpenCL backend
# ============================================================
add_library(argon2-opencl STATIC
    lib/argon2-opencl/device.cpp
    lib/argon2-opencl/globalcontext.cpp
    lib/argon2-opencl/kernelloader.cpp
    lib/argon2-opencl/programcontext.cpp
    lib/argon2-opencl/processingunit.cpp
    lib/argon2-opencl/kernelrunner.cpp
)
target_include_directories(argon2-opencl INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)
target_include_directories(argon2-opencl PRIVATE
    include/argon2-opencl
    lib/argon2-opencl
)
# C4267: kernelrunner.h:40, processingunit.cpp:119,128,143, kernelrunner.cpp:116,118,134 — size_t -> uint32_t/int
# C4101: kernelloader.cpp:36 (err), processingunit.cpp:49,89 (ex) — unused local variables
target_compile_options(argon2-opencl PRIVATE ${ARGON2_MSVC_WARN})
target_link_libraries(argon2-opencl
    argon2-gpu-common ${OpenCL_LIBRARIES}
)

# ============================================================
#  mm_gpu_gate — shared library (the actual GPU gate)
# ============================================================
set(GATE_SOURCE ${CMAKE_CURRENT_SOURCE_DIR}/../argon2d-gpu-gate.cpp)
if(NOT EXISTS ${GATE_SOURCE})
    message(FATAL_ERROR "Cannot find ../argon2d-gpu-gate.cpp")
endif()

add_library(mm_gpu_gate SHARED ${GATE_SOURCE})
target_compile_definitions(mm_gpu_gate PRIVATE EXPORT_SYMBOLS)
target_include_directories(mm_gpu_gate PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/include/argon2-gpu-common
    ${CMAKE_CURRENT_SOURCE_DIR}/include/argon2-cuda
    ${CMAKE_CURRENT_SOURCE_DIR}/include/argon2-opencl
)
# C4267: argon2d-gpu-gate.cpp:194 (size_t -> int), plus re-included headers kernelrunner.h:40, kernels.h:60
target_compile_options(mm_gpu_gate PRIVATE ${ARGON2_MSVC_WARN})

# Link with the static backends and required system libs
target_link_libraries(mm_gpu_gate
    argon2-cuda
    argon2-opencl
    argon2-gpu-common
    ${OpenCL_LIBRARIES}
)

if(CUDA_FOUND)
    target_link_libraries(mm_gpu_gate ${CUDA_LIBRARIES})
endif()

# LNK4098: cudart_static.lib pulls in /MT (LIBCMT), but our DLL uses /MD (MSVCRT).
# /NODEFAULTLIB:LIBCMT tells the linker to ignore the static CRT and use dynamic only.
# This is safe: CUDA runtime itself still works; we just avoid the duplicate symbol conflict.
if(MSVC)
    set_target_properties(mm_gpu_gate PROPERTIES
        LINK_FLAGS "/NODEFAULTLIB:LIBCMT"
    )
endif()

# Ensure output is libmm_gpu_gate so configure.ac AC_CHECK_FILE finds it
if(MSVC)
    set_target_properties(mm_gpu_gate PROPERTIES PREFIX "lib" SUFFIX ".dll"
        IMPORT_PREFIX "lib" IMPORT_SUFFIX ".dll.a")
elseif(MINGW)
    set_target_properties(mm_gpu_gate PROPERTIES PREFIX "lib" SUFFIX ".dll")
endif()

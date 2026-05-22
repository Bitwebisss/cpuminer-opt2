cmake_minimum_required(VERSION 3.18...4.0)

project(argon2-gpu CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ============================================================
#  MSVC runtime: MultiThreadedDLL (/MD) to prevent LNK2038.
#  Must be set BEFORE enable_language(CUDA) so nvcc inherits it.
# ============================================================
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
endif()

# ============================================================
#  OpenCL
#  Caller passes: -DOpenCL_LIBRARY=... -DOpenCL_INCLUDE_DIR=...
#  find_package(OpenCL) consumes those variables as hints directly.
# ============================================================
find_package(OpenCL REQUIRED)

# ============================================================
#  CUDA (modern CUDAToolkit, requires CMake 3.17+)
#  find_package(CUDAToolkit) auto-detects via CUDA_PATH env var.
#  Caller passes: -DNO_CUDA=FALSE to enable GPU build.
# ============================================================
set(HAVE_CUDA FALSE)

if(NOT NO_CUDA)
    find_package(CUDAToolkit QUIET)
    if(CUDAToolkit_FOUND)
        # Target GPU architectures (same as original -gencode flags):
        #   61        Pascal   (GTX 10xx)
        #   75        Turing   (RTX 20xx, GTX 16xx)
        #   80        Ampere   (A100)
        #   86-real   Ampere RTX 30xx  (binary code)
        #   86-virtual PTX for forward compatibility (was compute_86,compute_86)
        set(CMAKE_CUDA_ARCHITECTURES 61 75 80 86-real 86-virtual)
        enable_language(CUDA)
        set(HAVE_CUDA TRUE)
        message(STATUS "CUDA ${CUDAToolkit_VERSION} found -- GPU build enabled")
        add_compile_definitions(HAVE_CUDA=1)
    else()
        message(STATUS "CUDAToolkit not found -- building without CUDA")
    endif()
endif()

if(NOT HAVE_CUDA)
    add_compile_definitions(HAVE_CUDA=0)
    message(STATUS "Building without CUDA support")
endif()

# ============================================================
#  CUDA compiler flags (replaces legacy CUDA_NVCC_FLAGS).
#  Applied only to .cu files via COMPILE_LANGUAGE:CUDA generator expression.
# ============================================================
if(HAVE_CUDA)
    set(CUDA_EXTRA_FLAGS -O3 --ptxas-options=-v -lineinfo)
    if(MSVC)
        # Force nvcc to use the same dynamic CRT (/MD) as the rest of the project.
        list(APPEND CUDA_EXTRA_FLAGS -Xcompiler=/MD)
    else()
        list(APPEND CUDA_EXTRA_FLAGS --compiler-options=-fPIC)
    endif()
endif()

# ============================================================
#  argon2-gpu-common
# ============================================================
add_library(argon2-gpu-common STATIC
    lib/argon2-gpu-common/argon2params.cpp
    lib/argon2-gpu-common/blake2b.cpp
)
target_include_directories(argon2-gpu-common
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    PRIVATE
        include/argon2-gpu-common
        lib/argon2-gpu-common
)

# ============================================================
#  argon2-cuda -- CUDA backend or stub
# ============================================================
if(HAVE_CUDA)
    add_library(argon2-cuda STATIC
        lib/argon2-cuda/device.cpp
        lib/argon2-cuda/globalcontext.cpp
        lib/argon2-cuda/programcontext.cpp
        lib/argon2-cuda/processingunit.cpp
        lib/argon2-cuda/kernels.cu
    )
    set_target_properties(argon2-cuda PROPERTIES
        CUDA_STANDARD 17
        CUDA_STANDARD_REQUIRED ON
        CUDA_SEPARABLE_COMPILATION OFF
    )
    target_compile_options(argon2-cuda PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:${CUDA_EXTRA_FLAGS}>
    )
    target_include_directories(argon2-cuda PRIVATE
        ${CUDAToolkit_INCLUDE_DIRS}
        include/argon2-cuda
        lib/argon2-cuda
    )
    target_link_libraries(argon2-cuda
        PUBLIC  argon2-gpu-common
        PRIVATE CUDA::cudart
    )
else()
    add_library(argon2-cuda STATIC
        lib/argon2-cuda/nocuda.cpp
    )
    target_include_directories(argon2-cuda PRIVATE
        include/argon2-cuda
        lib/argon2-cuda
    )
    target_link_libraries(argon2-cuda PUBLIC argon2-gpu-common)
endif()

target_include_directories(argon2-cuda
    PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)

# ============================================================
#  argon2-opencl -- OpenCL backend
# ============================================================
add_library(argon2-opencl STATIC
    lib/argon2-opencl/device.cpp
    lib/argon2-opencl/globalcontext.cpp
    lib/argon2-opencl/kernelloader.cpp
    lib/argon2-opencl/programcontext.cpp
    lib/argon2-opencl/processingunit.cpp
    lib/argon2-opencl/kernelrunner.cpp
)
target_include_directories(argon2-opencl
    PUBLIC  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    PRIVATE include/argon2-opencl
            lib/argon2-opencl
)
target_link_libraries(argon2-opencl
    PUBLIC  argon2-gpu-common
    PRIVATE OpenCL::OpenCL
)

# ============================================================
#  mm_gpu_gate -- final shared library
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
target_link_libraries(mm_gpu_gate
    PRIVATE
        argon2-cuda
        argon2-opencl
        argon2-gpu-common
        OpenCL::OpenCL
)
if(HAVE_CUDA)
    target_link_libraries(mm_gpu_gate PRIVATE CUDA::cudart)
endif()

# bat expects the output named libmm_gpu_gate.dll
if(MSVC)
    set_target_properties(mm_gpu_gate PROPERTIES
        PREFIX        "lib"
        SUFFIX        ".dll"
        IMPORT_PREFIX "lib"
        IMPORT_SUFFIX ".dll.a"
    )
endif()

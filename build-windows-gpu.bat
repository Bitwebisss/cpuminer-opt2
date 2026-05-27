@echo off
setlocal

echo ============================================================
echo  cpuminer-opt3 Windows Build  [GPU ONLY]
echo  Stage 1: VS2019 + CUDA  -^>  libmm_gpu_gate.dll
echo  Stage 2: MSYS2 UCRT64  -^>  cpuminer*-GPU.exe  (8 CPU archs)
echo ============================================================
echo.

set "VS_VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "MSBUILD=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
set "MSYS2_BASH=C:\msys64\usr\bin\bash.exe"
set "GENDEF=C:\msys64\ucrt64\bin\gendef.exe"
set "DLLTOOL=C:\msys64\ucrt64\bin\dlltool.exe"

for %%I in ("%~dp0.") do set "PROJECT=%%~fI"
set "GPU_SRC=%PROJECT%\algo\argon2d\argon2-gpu"
set "GPU_BUILD=%GPU_SRC%\build_vs"
set "GPU_OUT=%GPU_BUILD%\Release"

echo Project:   %PROJECT%
echo CUDA_PATH: %CUDA_PATH%
echo.

:: ============================================================
::  PRE-FLIGHT CHECKS
:: ============================================================
echo [CHECK] VS2019...
if not exist "%VS_VCVARS%" echo MISSING: %VS_VCVARS%
if not exist "%VS_VCVARS%" goto :fail

echo [CHECK] MSBuild...
if not exist "%MSBUILD%" echo MISSING: %MSBUILD%
if not exist "%MSBUILD%" goto :fail

echo [CHECK] CUDA_PATH env var...
if "%CUDA_PATH%"=="" echo MISSING: CUDA_PATH not set
if "%CUDA_PATH%"=="" goto :fail

echo [CHECK] CUDA nvcc...
if not exist "%CUDA_PATH%\bin\nvcc.exe" echo MISSING: %CUDA_PATH%\bin\nvcc.exe
if not exist "%CUDA_PATH%\bin\nvcc.exe" goto :fail

echo [CHECK] MSYS2...
if not exist "%MSYS2_BASH%" echo MISSING: %MSYS2_BASH%
if not exist "%MSYS2_BASH%" goto :fail

echo [CHECK] Ensuring OpenCL headers and ICD are installed via MSYS2...
"%MSYS2_BASH%" --login -c "pacman -S --noconfirm --needed mingw-w64-ucrt-x86_64-opencl-headers mingw-w64-ucrt-x86_64-opencl-icd"
if errorlevel 1 echo ERROR: pacman failed to install OpenCL packages
if errorlevel 1 goto :fail

echo [CHECK] gendef...
if not exist "%GENDEF%" echo MISSING: %GENDEF%
if not exist "%GENDEF%" goto :fail

echo [CHECK] dlltool...
if not exist "%DLLTOOL%" echo MISSING: %DLLTOOL%
if not exist "%DLLTOOL%" goto :fail

echo [CHECK] argon2-gpu submodule...
if not exist "%GPU_SRC%\CMakeLists.txt" echo MISSING: %GPU_SRC%\CMakeLists.txt
if not exist "%GPU_SRC%\CMakeLists.txt" goto :fail

echo [CHECK] build-windows-stage2-gpu.sh...
if not exist "%PROJECT%\build-windows-stage2-gpu.sh" echo MISSING: %PROJECT%\build-windows-stage2-gpu.sh
if not exist "%PROJECT%\build-windows-stage2-gpu.sh" goto :fail

echo All checks passed.
echo.

:: ============================================================
::  STAGE 1-A: Load VS2019 x64 environment
:: ============================================================
echo [1/4] Loading VS2019 x64 environment...
call "%VS_VCVARS%"
if errorlevel 1 echo ERROR: vcvars64.bat failed
if errorlevel 1 goto :fail
echo [1/4] Done.
echo.

:: ============================================================
::  STAGE 1-B: Generate OpenCL.lib from MSYS2 OpenCL.dll
:: ============================================================
echo [2/4] Generating OpenCL.lib from MSYS2 OpenCL.dll...
if exist "%GPU_BUILD%" rmdir /s /q "%GPU_BUILD%"
mkdir "%GPU_BUILD%"
cd /d "%GPU_BUILD%"
"%GENDEF%" "C:\msys64\ucrt64\bin\OpenCL.dll"
if errorlevel 1 echo ERROR: gendef OpenCL.dll failed
if errorlevel 1 goto :fail
lib.exe /def:OpenCL.def /out:OpenCL.lib /machine:x64 /nologo
if errorlevel 1 echo ERROR: lib.exe OpenCL.lib failed
if errorlevel 1 goto :fail
echo   OpenCL.lib generated OK
echo.

set "GPU_SRC_FWD=%GPU_SRC:\=/%"
set "OPENCL_LIB_FWD=%GPU_BUILD:\=/%"
set "OPENCL_HEADERS_CLEAN=%GPU_BUILD%\opencl-headers"
if exist "%OPENCL_HEADERS_CLEAN%" rmdir /s /q "%OPENCL_HEADERS_CLEAN%"
mkdir "%OPENCL_HEADERS_CLEAN%\CL"
xcopy /s /y "C:\msys64\ucrt64\include\CL\*" "%OPENCL_HEADERS_CLEAN%\CL\" >nul
if errorlevel 1 echo ERROR: failed to copy OpenCL headers
if errorlevel 1 goto :fail
set "OPENCL_INC_FWD=%OPENCL_HEADERS_CLEAN:\=/%"

:: ============================================================
::  STAGE 1-C: cmake configure
:: ============================================================
echo [3/4] cmake configure...
cmake "%GPU_SRC_FWD%" -G "Visual Studio 16 2019" -A x64 -DNO_CUDA=FALSE -DOpenCL_LIBRARY="%OPENCL_LIB_FWD%/OpenCL.lib" -DOpenCL_INCLUDE_DIR="%OPENCL_INC_FWD%"
if errorlevel 1 echo ERROR: cmake failed
if errorlevel 1 goto :fail
echo [3/4] cmake OK.
echo.

:: ============================================================
::  STAGE 1-D: MSBuild -> libmm_gpu_gate.dll + import lib
:: ============================================================
echo [4/4] MSBuild -> libmm_gpu_gate.dll...
"%MSBUILD%" argon2-gpu.sln /t:mm_gpu_gate /p:Configuration=Release /p:Platform=x64 /m
if errorlevel 1 echo ERROR: MSBuild failed
if errorlevel 1 goto :fail
if not exist "%GPU_OUT%\libmm_gpu_gate.dll" echo ERROR: libmm_gpu_gate.dll not produced
if not exist "%GPU_OUT%\libmm_gpu_gate.dll" goto :fail

cd /d "%GPU_OUT%"
"%GENDEF%" libmm_gpu_gate.dll
if errorlevel 1 echo ERROR: gendef failed
if errorlevel 1 goto :fail
"%DLLTOOL%" -d libmm_gpu_gate.def -D libmm_gpu_gate.dll -l libmm_gpu_gate.dll.a
if errorlevel 1 echo ERROR: dlltool failed
if errorlevel 1 goto :fail
if not exist "%GPU_OUT%\libmm_gpu_gate.dll.a" echo ERROR: libmm_gpu_gate.dll.a not produced
if not exist "%GPU_OUT%\libmm_gpu_gate.dll.a" goto :fail

echo [4/4] Stage 1 complete.
echo   DLL:        %GPU_OUT%\libmm_gpu_gate.dll
echo   Import lib: %GPU_OUT%\libmm_gpu_gate.dll.a
echo.

:: ============================================================
::  STAGE 2: MSYS2 — GPU exe variants
:: ============================================================
echo [Stage 2] Building GPU exe variants via MSYS2...
cd /d "%PROJECT%"
set "GPU_OUT_FWD=%GPU_OUT:\=/%"
set "PROJ_FWD=%PROJECT:\=/%"
"%MSYS2_BASH%" --login -c "export PATH=/ucrt64/bin:/usr/bin:$PATH && PROJ=$(cygpath -u "%PROJ_FWD%") && GPU=$(cygpath -u "%GPU_OUT_FWD%") && export CPUMINER_GPU_GATE_WIN=$GPU && bash \"$PROJ/build-windows-stage2-gpu.sh\" \"$PROJ\""
if errorlevel 1 echo ERROR: Stage 2 GPU build failed
if errorlevel 1 goto :fail

echo.
echo ============================================================
echo  BUILD COMPLETE  [GPU]
echo  Archive: cpuminer-windows-gpu.zip
echo ============================================================
echo.
pause
goto :eof

:fail
echo.
echo ============================================================
echo  BUILD FAILED - read error above
echo ============================================================
echo.
pause

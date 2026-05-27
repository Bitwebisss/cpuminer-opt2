@echo off
setlocal

echo ============================================================
echo  cpuminer-opt3 Windows Build  [CPU / NO-GPU ONLY]
echo  Stage 2 only: MSYS2 UCRT64  -^>  cpuminer*.exe  (8 CPU archs)
echo  No CUDA, no VS2019, no libmm_gpu_gate.dll required.
echo ============================================================
echo.

set "MSYS2_BASH=C:\msys64\usr\bin\bash.exe"

for %%I in ("%~dp0.") do set "PROJECT=%%~fI"

echo Project: %PROJECT%
echo.

:: ============================================================
::  PRE-FLIGHT CHECKS
:: ============================================================
echo [CHECK] MSYS2...
if not exist "%MSYS2_BASH%" echo MISSING: %MSYS2_BASH%
if not exist "%MSYS2_BASH%" goto :fail

echo [CHECK] build-windows-stage2-cpu.sh...
if not exist "%PROJECT%\build-windows-stage2-cpu.sh" echo MISSING: %PROJECT%\build-windows-stage2-cpu.sh
if not exist "%PROJECT%\build-windows-stage2-cpu.sh" goto :fail

echo All checks passed.
echo.

:: ============================================================
::  STAGE 2: MSYS2 — CPU-only exe variants
:: ============================================================
echo [Building] CPU-only exe variants via MSYS2...
cd /d "%PROJECT%"
set "PROJ_FWD=%PROJECT:\=/%"
"%MSYS2_BASH%" --login -c "export PATH=/ucrt64/bin:/usr/bin:$PATH && PROJ=$(cygpath -u "%PROJ_FWD%") && bash \"$PROJ/build-windows-stage2-cpu.sh\" \"$PROJ\""
if errorlevel 1 echo ERROR: CPU build failed
if errorlevel 1 goto :fail

echo.
echo ============================================================
echo  BUILD COMPLETE  [CPU / NO-GPU]
echo  Archive: cpuminer-windows.zip
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

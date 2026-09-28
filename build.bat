@echo off
setlocal enabledelayedexpansion

echo ==========================================================
echo              Building Antigravity OS                      
echo ==========================================================

if not exist "bin" mkdir "bin"

:: Check for NASM
where nasm >nul 2>&1
if %ERRORLEVEL% neq 0 (
    if exist "%LOCALAPPDATA%\bin\NASM\nasm.exe" (
        set "NASM=%LOCALAPPDATA%\bin\NASM\nasm.exe"
    ) else if exist "%LOCALAPPDATA%\bin\nasm.exe" (
        set "NASM=%LOCALAPPDATA%\bin\nasm.exe"
    ) else if exist "%ProgramFiles%\NASM\nasm.exe" (
        set "NASM=%ProgramFiles%\NASM\nasm.exe"
    ) else if exist "%ProgramFiles(x86)%\NASM\nasm.exe" (
        set "NASM=%ProgramFiles(x86)%\NASM\nasm.exe"
    ) else (
        echo [ERROR] NASM assembler not found!
        echo Install it using: winget install NASM.NASM
        pause
        exit /b 1
    )
) else (
    set "NASM=nasm"
)

echo [1/3] Assembling MBR Bootloader...
%NASM% -f bin -i boot/ boot/bootloader.asm -o bin/bootloader.bin
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Bootloader assembly failed!
    exit /b 1
)

echo [2/3] Assembling Protected Mode Kernel...
%NASM% -f bin -i kernel/ kernel/kernel.asm -o bin/kernel.bin
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Kernel assembly failed!
    exit /b 1
)

echo [3/3] Creating bootable disk image (bin\os-image.bin)...
copy /b bin\bootloader.bin + bin\kernel.bin bin\os-image.bin >nul
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Failed to combine disk image!
    exit /b 1
)

echo [SUCCESS] OS Image built successfully!

:: Check for QEMU and offer to run
where qemu-system-x86_64 >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo Launching QEMU...
    qemu-system-x86_64 -drive format=raw,file=bin/os-image.bin
) else if exist "%ProgramFiles%\qemu\qemu-system-x86_64.exe" (
    echo Launching QEMU...
    "%ProgramFiles%\qemu\qemu-system-x86_64.exe" -drive format=raw,file=bin/os-image.bin
) else (
    echo QEMU is not installed. You can install it using:
    echo   winget install SoftwareFreedomConservancy.QEMU
)

pause

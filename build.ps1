# ==============================================================================
# Antigravity OS - PowerShell Build & Run Script
# ==============================================================================

[CmdletBinding()]
param(
    [switch]$Run,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

$RootDir   = $PSScriptRoot
$BootDir   = Join-Path $RootDir "boot"
$KernelDir = Join-Path $RootDir "kernel"
$BinDir    = Join-Path $RootDir "bin"

$BootAsm   = Join-Path $BootDir "bootloader.asm"
$KernelAsm = Join-Path $KernelDir "kernel.asm"
$BootBin   = Join-Path $BinDir "bootloader.bin"
$KernelBin = Join-Path $BinDir "kernel.bin"
$OsImage   = Join-Path $BinDir "os-image.bin"

if ($Clean) {
    Write-Host "[CLEAN] Removing build artifacts in $BinDir..." -ForegroundColor Yellow
    if (Test-Path $BinDir) { Remove-Item $BinDir -Recurse -Force }
    Write-Host "[CLEAN] Done." -ForegroundColor Green
    return
}

# Ensure output directory exists
if (-not (Test-Path $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir | Out-Null
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "             Building Antigravity OS                      " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Check for NASM
$NasmCmd = Get-Command nasm -ErrorAction SilentlyContinue
if (-not $NasmCmd) {
    # Check common installation locations on Windows
    $CommonPaths = @(
        "$env:LOCALAPPDATA\bin\NASM\nasm.exe",
        "$env:LOCALAPPDATA\bin\nasm.exe",
        "$env:LOCALAPPDATA\Programs\NASM\nasm.exe",
        "$env:ProgramFiles\NASM\nasm.exe",
        "${env:ProgramFiles(x86)}\NASM\nasm.exe"
    )
    foreach ($path in $CommonPaths) {
        if (Test-Path $path) {
            $NasmCmd = $path
            # Also add to session PATH for convenience
            $nasmDir = Split-Path $path
            if ($env:Path -notlike "*$nasmDir*") {
                $env:Path = "$nasmDir;$env:Path"
            }
            break
        }
    }
}

if (-not $NasmCmd) {
    Write-Host "[ERROR] NASM assembler not found in PATH!" -ForegroundColor Red
    Write-Host "Please install NASM via one of the following:" -ForegroundColor Yellow
    Write-Host "  winget install NASM.NASM" -ForegroundColor White
    Write-Host "  choco install nasm" -ForegroundColor White
    Write-Host "  sudo apt install nasm (inside WSL/Ubuntu)" -ForegroundColor White
    exit 1
}

Write-Host "[1/3] Assembling MBR Bootloader ($BootAsm)..." -ForegroundColor Magenta
& $NasmCmd -f bin -i "$BootDir/" $BootAsm -o $BootBin
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAILED] Bootloader assembly failed." -ForegroundColor Red
    exit 1
}

$BootSize = (Get-Item $BootBin).Length
Write-Host "      Bootloader binary size: $BootSize bytes (Must be exactly 512 bytes)" -ForegroundColor Gray
if ($BootSize -ne 512) {
    Write-Host "[ERROR] Bootloader size is not 512 bytes!" -ForegroundColor Red
    exit 1
}

Write-Host "[2/3] Assembling Protected Mode Kernel ($KernelAsm)..." -ForegroundColor Magenta
& $NasmCmd -f bin -w-label-redef-late -i "$KernelDir/" $KernelAsm -o $KernelBin
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAILED] Kernel assembly failed." -ForegroundColor Red
    exit 1
}

$KernelSize = (Get-Item $KernelBin).Length
Write-Host "      Kernel binary size: $KernelSize bytes" -ForegroundColor Gray

Write-Host "[3/3] Creating bootable disk image ($OsImage)..." -ForegroundColor Magenta
# Stop any active QEMU instances holding a file lock on os-image.bin
Get-Process -Name "qemu-system-x86_64", "qemu-system-i386" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 200

# 512 sectors = 256 KB total disk image (covers Bootloader, 64KB Kernel, Superblock, Inodes, and Data blocks)
$totalSectors = 512
$fullImage = New-Object byte[] ($totalSectors * 512)

$bootBytes   = [System.IO.File]::ReadAllBytes($BootBin)
$kernelBytes = [System.IO.File]::ReadAllBytes($KernelBin)

# Copy Bootloader (LBA 0)
[System.Buffer]::BlockCopy($bootBytes, 0, $fullImage, 0, $bootBytes.Length)

# Copy Kernel (LBA 1..128)
[System.Buffer]::BlockCopy($kernelBytes, 0, $fullImage, $bootBytes.Length, $kernelBytes.Length)

# Check if existing os-image.bin already contains an active AFS filesystem
$preserveFs = $false
if ((Test-Path $OsImage) -and ((Get-Item $OsImage).Length -ge ($totalSectors * 512))) {
    $existing = [System.IO.File]::ReadAllBytes($OsImage)
    $sb = 129 * 512
    if ($existing[$sb] -eq [byte][char]'A' -and $existing[$sb+1] -eq [byte][char]'F' -and $existing[$sb+2] -eq [byte][char]'S' -and $existing[$sb+3] -eq [byte][char]'1') {
        [System.Buffer]::BlockCopy($existing, $sb, $fullImage, $sb, ($totalSectors * 512) - $sb)
        $preserveFs = $true
        Write-Host "      [FS] Preserved existing AntigravityFS files and disk data." -ForegroundColor Green
    }
}

if (-not $preserveFs) {
    Write-Host "      [FS] Initializing AntigravityFS volume with sample files..." -ForegroundColor Cyan

    # Superblock at LBA 129 (offset 129 * 512 = 66048)
    $sbOffset = 129 * 512
    $magic = [System.Text.Encoding]::ASCII.GetBytes("AFS1")
    [System.Buffer]::BlockCopy($magic, 0, $fullImage, $sbOffset, 4)
    [System.BitConverter]::GetBytes([int]512).CopyTo($fullImage, $sbOffset + 4)  # Total sectors
    [System.BitConverter]::GetBytes([int]130).CopyTo($fullImage, $sbOffset + 8)  # Inode LBA
    [System.BitConverter]::GetBytes([int]132).CopyTo($fullImage, $sbOffset + 12) # Data LBA
    [System.BitConverter]::GetBytes([int]32).CopyTo($fullImage, $sbOffset + 16)  # Max inodes

    # Inode 0: welcome.txt
    $wText = "Welcome to Antigravity OS [64-bit Long Mode]!`nPersistent storage powered by AntigravityFS (AFS) and ATA PIO."
    $wBytes = [System.Text.Encoding]::ASCII.GetBytes($wText)
    $in0Offset = 130 * 512
    $name0 = [System.Text.Encoding]::ASCII.GetBytes("welcome.txt")
    [System.Buffer]::BlockCopy($name0, 0, $fullImage, $in0Offset, $name0.Length)
    [System.BitConverter]::GetBytes([int]$wBytes.Length).CopyTo($fullImage, $in0Offset + 16)
    [System.BitConverter]::GetBytes([int16]132).CopyTo($fullImage, $in0Offset + 20) # LBA 132
    [System.BitConverter]::GetBytes([int16]1).CopyTo($fullImage, $in0Offset + 22)  # 1 sector
    $fullImage[$in0Offset + 24] = 1 # Allocated flag
    [System.Buffer]::BlockCopy($wBytes, 0, $fullImage, 132 * 512, $wBytes.Length)

    # Inode 1: readme.txt
    $rText = "AntigravityFS Commands:`n  ls / dir         - List directory`n  cat <file>       - Read file content`n  touch <file>     - Create empty file`n  write <file> <t> - Write text to file`n  rm <file>        - Delete file`n  df               - Storage statistics"
    $rBytes = [System.Text.Encoding]::ASCII.GetBytes($rText)
    $in1Offset = (130 * 512) + 32
    $name1 = [System.Text.Encoding]::ASCII.GetBytes("readme.txt")
    [System.Buffer]::BlockCopy($name1, 0, $fullImage, $in1Offset, $name1.Length)
    [System.BitConverter]::GetBytes([int]$rBytes.Length).CopyTo($fullImage, $in1Offset + 16)
    [System.BitConverter]::GetBytes([int16]133).CopyTo($fullImage, $in1Offset + 20) # LBA 133
    [System.BitConverter]::GetBytes([int16]1).CopyTo($fullImage, $in1Offset + 22)  # 1 sector
    $fullImage[$in1Offset + 24] = 1 # Allocated flag
    [System.Buffer]::BlockCopy($rBytes, 0, $fullImage, 133 * 512, $rBytes.Length)
}

[System.IO.File]::WriteAllBytes($OsImage, $fullImage)

Write-Host "[SUCCESS] Bootable disk image created successfully!" -ForegroundColor Green
Write-Host "          Disk Image: $OsImage ($($fullImage.Length) bytes, $totalSectors sectors)" -ForegroundColor Green

# Locate QEMU
$QemuCmd = Get-Command qemu-system-x86_64, qemu-system-i386 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $QemuCmd) {
    $QemuPaths = @(
        "$env:ProgramFiles\qemu\qemu-system-x86_64.exe",
        "${env:ProgramFiles(x86)}\qemu\qemu-system-x86_64.exe"
    )
    foreach ($path in $QemuPaths) {
        if (Test-Path $path) {
            $QemuCmd = $path
            break
        }
    }
}

if ($Run -or ($PSCmdlet.MyInvocation.BoundParameters.ContainsKey("Run"))) {
    if (-not $QemuCmd) {
        Write-Host "[WARN] QEMU not found. Install QEMU to run the OS image directly:" -ForegroundColor Yellow
        Write-Host "  winget install SoftwareFreedomConservancy.QEMU" -ForegroundColor White
        Write-Host "  choco install qemu" -ForegroundColor White
    } else {
        Write-Host "[RUN] Booting Antigravity OS in QEMU ($QemuCmd)..." -ForegroundColor Cyan
        & $QemuCmd -drive "format=raw,file=$OsImage" -netdev user,id=net0,hostfwd=tcp::8888-:80 -device rtl8139,netdev=net0
    }
} else {
    Write-Host "`nTo run your OS in QEMU, run:" -ForegroundColor Yellow
    Write-Host "  .\build.ps1 -Run" -ForegroundColor White
    Write-Host "  or: qemu-system-x86_64 -drive format=raw,file=bin\os-image.bin -netdev user,id=net0,hostfwd=tcp::8888-:80 -device rtl8139,netdev=net0" -ForegroundColor White
}

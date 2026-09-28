# Antigravity OS - Windows wrapper around tools/build.py (kept for muscle memory).
#   .\build.ps1              build
#   .\build.ps1 -Run         build and boot in QEMU
#   .\build.ps1 -Headless    boot without a window (serial console here)
#   .\build.ps1 -Test        run the test suite
#   .\build.ps1 -Fresh       reformat the AFS disk from rootfs\ (combine with -Run)
#   .\build.ps1 -Clean       delete build\
# Anything else: python tools\build.py --help
[CmdletBinding()]
param([switch]$Run, [switch]$Headless, [switch]$Test, [switch]$Fresh, [switch]$Clean)

$ErrorActionPreference = "Stop"

if (Get-Command py -ErrorAction SilentlyContinue) {
    $exe = "py"; $prefix = @("-3")
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $exe = "python"; $prefix = @()
} else {
    throw "Python 3 not found. Install it with: winget install Python.Python.3.12"
}

$script = Join-Path $PSScriptRoot "tools\build.py"
if ($Clean)        { $buildArgs = @("clean") }
elseif ($Test)     { $buildArgs = @("test") }
elseif ($Headless) { $buildArgs = @("run", "--headless") }
elseif ($Run)      { $buildArgs = @("run") }
else               { $buildArgs = @() }

if ($Fresh -and -not $Clean) {
    if ($Run -or $Headless) { $buildArgs += "--fresh" }
    else { $buildArgs = @("--fresh") + $buildArgs }
}

& $exe @prefix $script @buildArgs
exit $LASTEXITCODE

$qemu = "$env:ProgramFiles\qemu\qemu-system-x86_64.exe"
if (-not (Test-Path $qemu)) {
    Write-Host "QEMU not found at $qemu"
    exit 1
}

# Clean any previous artifacts
if (Test-Path "screen_gui.ppm") { Remove-Item "screen_gui.ppm" -Force }
if (Test-Path "screen_gui.png") { Remove-Item "screen_gui.png" -Force }
if (Test-Path "screen_cli.ppm") { Remove-Item "screen_cli.ppm" -Force }
if (Test-Path "screen_cli.png") { Remove-Item "screen_cli.png" -Force }

# Kill existing QEMU
Get-Process -Name "qemu-system-x86_64" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

Write-Host "[TEST] Launching QEMU with BGA Graphics and RTL8139..." -ForegroundColor Cyan
$proc = Start-Process -FilePath $qemu -ArgumentList "-drive format=raw,file=bin\os-image.bin -netdev user,id=net0,hostfwd=tcp::8888-:80 -device rtl8139,netdev=net0 -vga std -display none -qmp tcp:127.0.0.1:4445,server,nowait" -PassThru

# Wait 2 seconds for OS to boot
Start-Sleep -Seconds 2

try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 4445)
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.AutoFlush = $true

    # Read greeting
    $null = $reader.ReadLine()

    # Enter QMP capabilities
    $writer.WriteLine('{"execute":"qmp_capabilities"}')
    $null = $reader.ReadLine()

    function Send-Key($k) {
        $writer.WriteLine("{`"execute`":`"human-monitor-command`",`"arguments`":{`"command-line`":`"sendkey $k`"}}")
        $null = $reader.ReadLine()
        Start-Sleep -Milliseconds 40
    }

    function Send-Cmd($text) {
        foreach ($ch in $text.ToCharArray()) {
            $k = "$ch"
            if ($ch -eq '.') { $k = "dot" }
            elseif ($ch -eq ' ') { $k = "spc" }
            elseif ($ch -eq '-') { $k = "minus" }
            elseif ($ch -eq '/') { $k = "slash" }

            Send-Key $k
        }
        Send-Key "ret"
    }

    Write-Host "[TEST] Sending 'gui' command to launch 1024x768 Desktop..." -ForegroundColor Green
    Send-Cmd "gui"
    Start-Sleep -Seconds 2

    # Take screenshot of GUI desktop
    Write-Host "[TEST] Capturing GUI desktop screenshot (screendump screen_gui.ppm)..." -ForegroundColor Yellow
    $writer.WriteLine('{"execute":"human-monitor-command","arguments":{"command-line":"screendump screen_gui.ppm"}}')
    $null = $reader.ReadLine()
    Start-Sleep -Milliseconds 800

    # Test arrow keys to nudge cursor and press Space to draw on canvas
    Write-Host "[TEST] Testing interactive keyboard cursor nudging and drawing..." -ForegroundColor Magenta
    Send-Key "down"
    Send-Key "down"
    Send-Key "down"
    Send-Key "right"
    Send-Key "right"
    Send-Key "spc"
    Start-Sleep -Milliseconds 300

    # Test returning from GUI to CLI via ESC
    Write-Host "[TEST] Pressing ESC to exit GUI and return to CLI..." -ForegroundColor Cyan
    Send-Key "esc"
    Start-Sleep -Seconds 1

    # Take screenshot of returned CLI
    Write-Host "[TEST] Capturing returned CLI screenshot (screendump screen_cli.ppm)..." -ForegroundColor Yellow
    $writer.WriteLine('{"execute":"human-monitor-command","arguments":{"command-line":"screendump screen_cli.ppm"}}')
    $null = $reader.ReadLine()
    Start-Sleep -Milliseconds 500

    # Quit QEMU
    $writer.WriteLine('{"execute":"quit"}')
    Start-Sleep -Milliseconds 500

    $client.Close()
} catch {
    Write-Host "[ERROR] QMP Exception: $_" -ForegroundColor Red
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

# Convert PPM files to PNG
python -c "
from PIL import Image
import os

for base in ['screen_gui', 'screen_cli']:
    ppm = f'{base}.ppm'
    png = f'{base}.png'
    if os.path.exists(ppm):
        img = Image.open(ppm)
        img.save(png)
        print(f'Converted {ppm} -> {png} (Size: {img.size})')
"

Write-Host "[TEST] Completed." -ForegroundColor Green

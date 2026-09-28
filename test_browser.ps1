$qemu = "$env:ProgramFiles\qemu\qemu-system-x86_64.exe"
if (-not (Test-Path $qemu)) {
    Write-Host "QEMU not found at $qemu"
    exit 1
}

# Kill any existing QEMU processes
Get-Process -Name "qemu-system-x86_64" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

Write-Host "[TEST] Launching QEMU for CyberSurf Browser Test..." -ForegroundColor Cyan
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

    function Send-HMP($cmd) {
        $msg = @{
            execute = "human-monitor-command"
            arguments = @{
                "command-line" = $cmd
            }
        } | ConvertTo-Json -Compress
        $writer.WriteLine($msg)
        $resp = $reader.ReadLine()
        Start-Sleep -Milliseconds 60
        return $resp
    }

    function Send-Key($k) {
        $null = Send-HMP "sendkey $k"
    }

    function Send-Text($text) {
        foreach ($ch in $text.ToCharArray()) {
            $k = "$ch"
            if ($ch -eq '.') { $k = "dot" }
            elseif ($ch -eq ' ') { $k = "spc" }
            elseif ($ch -eq '-') { $k = "minus" }
            elseif ($ch -eq '/') { $k = "slash" }
            elseif ($ch -eq '_') { $k = "shift-minus" }
            elseif ($ch -eq ':') { $k = "shift-semicolon" }
            elseif ($ch -ge 'A' -and $ch -le 'Z') {
                $low = "$ch".ToLower()
                $k = "shift-$low"
            }
            Send-Key $k
        }
    }

    function Send-Cmd($text) {
        Send-Text $text
        Send-Key "ret"
        Start-Sleep -Milliseconds 250
    }

    function Screendump($filename) {
        Write-Host "[TEST] Screendump: $filename" -ForegroundColor Yellow
        $null = Send-HMP "screendump $filename"
        Start-Sleep -Milliseconds 400
    }

    # Track virtual mouse coordinates (OS starts mouse at 512, 384)
    $global:curX = 512
    $global:curY = 384

    function Mouse-MoveTo($targetX, $targetY) {
        $dx = $targetX - $global:curX
        $dy = $targetY - $global:curY
        $global:curX = $targetX
        $global:curY = $targetY
        $null = Send-HMP "mouse_move $dx $dy"
        Start-Sleep -Milliseconds 150
    }

    function Mouse-Click($targetX, $targetY) {
        Mouse-MoveTo $targetX $targetY
        $null = Send-HMP "mouse_button 1"
        Start-Sleep -Milliseconds 120
        $null = Send-HMP "mouse_button 0"
        Start-Sleep -Milliseconds 300
    }

    # Step 1: Launch Web Browser from CLI ('browser')
    Write-Host "[TEST] Step 1: Launching CyberSurf Web Browser ('browser')..." -ForegroundColor Green
    Send-Cmd "browser"
    Start-Sleep -Seconds 1
    Screendump "screen_browser_home.ppm"

    # Step 2: Click [ Demo HTML ] bookmark pill
    # win3_x = 75, win3_y = 46
    # Demo pill is at x: 75 + 119 = 194, y: 46 + 66 = 112
    Write-Host "[TEST] Step 2: Clicking [ Demo HTML ] Bookmark Pill..." -ForegroundColor Green
    Mouse-Click 194 112
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_demo.ppm"

    # Step 3: Click [ Telemetry ] bookmark pill
    # Telemetry pill is at x: 75 + 204 = 279, y: 112
    Write-Host "[TEST] Step 3: Clicking [ Telemetry ] Bookmark Pill..." -ForegroundColor Green
    Mouse-Click 279 112
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_status.ppm"

    # Step 4: Click [ AFS Docs ] bookmark pill (loads afs://readme.txt from disk)
    # AFS Docs pill is at x: 75 + 287 = 362, y: 112
    Write-Host "[TEST] Step 4: Clicking [ AFS Docs ] Bookmark Pill..." -ForegroundColor Green
    Mouse-Click 362 112
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_afs.ppm"

    # Step 5: Click [ Home ] Toolbar Button
    # Home button is at x: 75 + 116 = 191, y: 46 + 41 = 87
    Write-Host "[TEST] Step 5: Clicking [ Home ] Toolbar Button..." -ForegroundColor Green
    Mouse-Click 191 87
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_back_home.ppm"

    # Step 6: Click Address Bar and Type URL
    # Address bar is at x: 75 + 300 = 375, y: 46 + 41 = 87
    Write-Host "[TEST] Step 6: Clicking URL bar and typing 'http://antigravity.os/status'..." -ForegroundColor Green
    Mouse-Click 375 87
    # Clear existing URL by sending backspaces
    for ($i = 0; $i -lt 30; $i++) {
        Send-Key "backspace"
    }
    Send-Text "http://antigravity.os/status"
    Start-Sleep -Milliseconds 200
    Send-Key "ret"
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_typed_url.ppm"

    # Step 7: Maximize Browser Window (Green Dot at 75 + 46 = 121, 46 + 14 = 60)
    Write-Host "[TEST] Step 7: Clicking Green Dot to Maximize Browser Window..." -ForegroundColor Green
    Mouse-Click 121 60
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_maximized.ppm"

    # Step 8: Restore Browser Window (Green Dot on maximized window at 20 + 46 = 66, 45 + 14 = 59)
    Write-Host "[TEST] Step 8: Clicking Green Dot again to Restore Window..." -ForegroundColor Green
    Mouse-Click 66 59
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_restored.ppm"

    # Step 9: Minimize Browser Window (Yellow Dot at 75 + 32 = 107, 46 + 14 = 60)
    Write-Host "[TEST] Step 9: Clicking Yellow Dot to Minimize Browser Window..." -ForegroundColor Green
    Mouse-Click 107 60
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_minimized.ppm"

    # Step 10: Restore via Taskbar [Browser] Pill (x: 470, y: 15)
    Write-Host "[TEST] Step 10: Clicking Taskbar [Browser] Pill to Reopen..." -ForegroundColor Green
    Mouse-Click 470 15
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_reopened.ppm"

    # Step 11: Close Browser Window (Red Dot at 75 + 16 = 91, 46 + 14 = 60)
    Write-Host "[TEST] Step 11: Clicking Red Dot to Close Browser Window..." -ForegroundColor Green
    Mouse-Click 91 60
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_closed.ppm"

    # Step 12: In GUI Terminal, type 'browser' to re-launch
    Write-Host "[TEST] Step 12: In GUI Terminal, typing 'browser' to re-open..." -ForegroundColor Green
    Send-Cmd "browser"
    Start-Sleep -Milliseconds 600
    Screendump "screen_browser_term_launch.ppm"

    # Step 13: Exit GUI to CLI via ESC
    Write-Host "[TEST] Step 13: Pressing ESC to return to CLI..." -ForegroundColor Green
    Send-Key "esc"
    Start-Sleep -Seconds 1
    Screendump "screen_browser_cli_done.ppm"

    # Quit QEMU
    $null = Send-HMP "quit"
    Start-Sleep -Milliseconds 300
    $client.Close()
} catch {
    Write-Host "[ERROR] QMP Exception: $_" -ForegroundColor Red
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

# Convert all PPM to PNG
python -c "
import os
from convert_ppm import ppm_to_png

files = [
    'screen_browser_home.ppm',
    'screen_browser_demo.ppm',
    'screen_browser_status.ppm',
    'screen_browser_afs.ppm',
    'screen_browser_back_home.ppm',
    'screen_browser_typed_url.ppm',
    'screen_browser_maximized.ppm',
    'screen_browser_restored.ppm',
    'screen_browser_minimized.ppm',
    'screen_browser_reopened.ppm',
    'screen_browser_closed.ppm',
    'screen_browser_term_launch.ppm',
    'screen_browser_cli_done.ppm'
]
for f in files:
    png = f.replace('.ppm', '.png')
    if os.path.exists(f):
        ppm_to_png(f, png)
        print(f'Converted {f} -> {png}')
"
Write-Host "[TEST] CyberSurf Web Browser verification test suite complete!" -ForegroundColor Green

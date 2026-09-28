$qemu = "$env:ProgramFiles\qemu\qemu-system-x86_64.exe"
if (-not (Test-Path $qemu)) {
    Write-Host "QEMU not found at $qemu"
    exit 1
}

# Kill any existing QEMU processes
Get-Process -Name "qemu-system-x86_64" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

Write-Host "[TEST] Launching QEMU for i3 Virtual Workspaces Test..." -ForegroundColor Cyan
$proc = Start-Process -FilePath $qemu -ArgumentList "-drive format=raw,file=bin\os-image.bin -netdev user,id=net0,hostfwd=tcp::8888-:80 -device rtl8139,netdev=net0 -vga std -display none -qmp tcp:127.0.0.1:4447,server,nowait" -PassThru

# Wait 2 seconds for OS to boot
Start-Sleep -Seconds 2

try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 4447)
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
        Start-Sleep -Milliseconds 80
        return $resp
    }

    function Send-Key($k) {
        $null = Send-HMP "sendkey $k"
        Start-Sleep -Milliseconds 120
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
        Start-Sleep -Milliseconds 300
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

    # Step 1: Boot into CLI and launch GUI desktop
    Write-Host "[TEST] Step 1: Launching GUI desktop ('gui')..." -ForegroundColor Green
    Send-Cmd "gui"
    Start-Sleep -Milliseconds 800
    Screendump "screen_ws_01_init.ppm"

    # Step 2: Switch to Workspace 2 (CyberSurf Web Browser) using F2
    Write-Host "[TEST] Step 2: Pressing F2 -> Switch to Workspace 2 (Web)..." -ForegroundColor Green
    Send-Key "f2"
    Start-Sleep -Milliseconds 600
    Screendump "screen_ws_02_ws2_browser.ppm"

    # Step 3: Switch to Workspace 3 (Cyber Canvas) using F3
    Write-Host "[TEST] Step 3: Pressing F3 -> Switch to Workspace 3 (Dev/Canvas)..." -ForegroundColor Green
    Send-Key "f3"
    Start-Sleep -Milliseconds 600
    Screendump "screen_ws_03_ws3_canvas.ppm"

    # Step 4: Switch to Workspace 4 (System Monitor) using F4
    Write-Host "[TEST] Step 4: Pressing F4 -> Switch to Workspace 4 (Sys)..." -ForegroundColor Green
    Send-Key "f4"
    Start-Sleep -Milliseconds 600
    Screendump "screen_ws_04_ws4_sysinfo.ppm"

    # Step 5: Click taskbar Workspace 1 pill [ 1:TERM ] (x: 114, y: 16)
    Write-Host "[TEST] Step 5: Clicking taskbar pill [ 1:TERM ] -> Switch back to Workspace 1..." -ForegroundColor Green
    Mouse-Click 114 16
    Start-Sleep -Milliseconds 600
    Screendump "screen_ws_05_clicked_ws1.ppm"

    # Step 6: Test terminal 'ws' status command
    Write-Host "[TEST] Step 6: In terminal, typing 'ws' command..." -ForegroundColor Green
    Send-Cmd "ws"
    Start-Sleep -Milliseconds 600
    Screendump "screen_ws_06_ws_status.ppm"

    # Step 7: Test terminal 'ws 2' switch command
    Write-Host "[TEST] Step 7: In terminal, typing 'ws 2' command..." -ForegroundColor Green
    Send-Cmd "ws 2"
    Start-Sleep -Milliseconds 600
    Screendump "screen_ws_07_ws_cmd_switch.ppm"

    # Step 8: Click titlebar [WS 2] badge on CyberSurf window to cycle it to WS 3
    # win3_x = 60, win3_w = 904 -> badge at x: 60 + 904 - 35 = 929, y: 52 + 15 = 67
    Write-Host "[TEST] Step 8: Clicking titlebar [WS 2] badge to cycle browser to Workspace 3..." -ForegroundColor Green
    Mouse-Click 929 67
    Start-Sleep -Milliseconds 600

    # Switch to Workspace 3 to see the moved browser alongside Canvas
    Write-Host "[TEST] Step 8b: Switching to Workspace 3 to verify moved window..." -ForegroundColor Green
    Send-Key "f3"
    Start-Sleep -Milliseconds 600
    Screendump "screen_ws_08_window_moved_ws3.ppm"

    # Step 9: Press Shift+F1 to move the focused window (browser) back to Workspace 1
    Write-Host "[TEST] Step 9: Pressing Shift+F1 to move window back to Workspace 1..." -ForegroundColor Green
    Send-Key "shift-f1"
    Start-Sleep -Milliseconds 600

    # Switch to Workspace 1 (F1)
    Write-Host "[TEST] Step 9b: Switching to Workspace 1 to see restored window..." -ForegroundColor Green
    Send-Key "f1"
    Start-Sleep -Milliseconds 600
    Screendump "screen_ws_09_shift_f1_moved.ppm"

    # Step 10: Exit GUI cleanly with ESC
    Write-Host "[TEST] Step 10: Pressing ESC to return to CLI..." -ForegroundColor Green
    Send-Key "esc"
    Start-Sleep -Milliseconds 800
    Screendump "screen_ws_10_cli_exit.ppm"

    # Close QMP
    $writer.WriteLine('{"execute":"quit"}')
    Start-Sleep -Milliseconds 500

} finally {
    if ($client) { $client.Close() }
    if ($proc -and -not $proc.HasExited) { $proc.Kill() }
}

# Convert PPM screendumps to PNG using convert_ppm.py
python -c "
import glob, os
from convert_ppm import ppm_to_png
for ppm in sorted(glob.glob('screen_ws_*.ppm')):
    png = ppm.replace('.ppm', '.png')
    ppm_to_png(ppm, png)
    os.remove(ppm)
    print(f'Converted {ppm} -> {png}')
"

Write-Host "[TEST] i3 Virtual Workspaces test suite complete!" -ForegroundColor Cyan

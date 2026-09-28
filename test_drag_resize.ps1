$qemu = "$env:ProgramFiles\qemu\qemu-system-x86_64.exe"
if (-not (Test-Path $qemu)) {
    Write-Host "QEMU not found at $qemu"
    exit 1
}

# Kill any existing QEMU processes
Get-Process -Name "qemu-system-x86_64" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

Write-Host "[TEST] Launching QEMU for Window Drag & Resize Test..." -ForegroundColor Cyan
$proc = Start-Process -FilePath $qemu -ArgumentList "-drive format=raw,file=bin\os-image.bin -netdev user,id=net0,hostfwd=tcp::8888-:80 -device rtl8139,netdev=net0 -vga std -display none -qmp tcp:127.0.0.1:4446,server,nowait" -PassThru

# Wait 2 seconds for OS to boot
Start-Sleep -Seconds 2

try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 4446)
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

    function Mouse-Drag($startX, $startY, $endX, $endY, $steps = 6) {
        Mouse-MoveTo $startX $startY
        $null = Send-HMP "mouse_button 1"
        Start-Sleep -Milliseconds 150
        for ($i = 1; $i -le $steps; $i++) {
            $midX = [int]($startX + ($endX - $startX) * $i / $steps)
            $midY = [int]($startY + ($endY - $startY) * $i / $steps)
            $dx = $midX - $global:curX
            $dy = $midY - $global:curY
            $global:curX = $midX
            $global:curY = $midY
            $null = Send-HMP "mouse_move $dx $dy"
            Start-Sleep -Milliseconds 100
        }
        $null = Send-HMP "mouse_button 0"
        Start-Sleep -Milliseconds 300
    }

    # Step 1: Launch GUI desktop ('gui')
    Write-Host "[TEST] Step 1: Launching GUI Desktop ('gui')..." -ForegroundColor Green
    Send-Cmd "gui"
    Start-Sleep -Seconds 1
    Screendump "screen_drag_01_initial.ppm"

    # Step 2: Drag Window 1 (Terminal) by its titlebar!
    # Terminal initial: x = 505, y = 50, w = 475, h = 325.
    # Titlebar grab at: x = 650, y = 62.
    # Drag to: x = 200, y = 140 (moving 450px left, 78px down).
    Write-Host "[TEST] Step 2: Dragging Terminal window by its titlebar..." -ForegroundColor Green
    Mouse-Drag 650 62 200 140
    Start-Sleep -Milliseconds 600
    Screendump "screen_drag_02_term_moved.ppm"

    # Step 3: Resize Window 1 (Terminal) using bottom-right resize grip!
    # Terminal now at x = 505 - 450 = 55, y = 50 + 78 = 128, w = 475, h = 325.
    # Bottom-right corner is at: x = 55 + 475 = 530, y = 128 + 325 = 453.
    # Drag outward to: x = 680, y = 550 (+150w, +97h).
    Write-Host "[TEST] Step 3: Resizing Terminal window from bottom-right grip..." -ForegroundColor Green
    Mouse-Drag 525 448 680 550
    Start-Sleep -Milliseconds 600
    Screendump "screen_drag_03_term_resized.ppm"

    # Step 4: Click into resized Terminal and run commands!
    Write-Host "[TEST] Step 4: Typing 'sysinfo' and 'ls' in resized Terminal..." -ForegroundColor Green
    # Click terminal interior to ensure focus
    Mouse-Click 200 200
    Send-Cmd "sysinfo"
    Start-Sleep -Milliseconds 400
    Send-Cmd "ls"
    Start-Sleep -Milliseconds 400
    Screendump "screen_drag_04_term_typed.ppm"

    # Step 5: Drag Window 0 (System Monitor)
    # Win 0 initial: x = 40, y = 50, w = 440, h = 325.
    # Grab titlebar at x = 200, y = 62.
    # Drag to x = 550, y = 220.
    Write-Host "[TEST] Step 5: Dragging System Monitor window to the right..." -ForegroundColor Green
    Mouse-Drag 200 62 550 220
    Start-Sleep -Milliseconds 600
    Screendump "screen_drag_05_sys_moved.ppm"

    # Step 6: Launch CyberSurf Web Browser from Terminal!
    Write-Host "[TEST] Step 6: Opening CyberSurf Web Browser ('browser')..." -ForegroundColor Green
    Mouse-Click 200 200
    Send-Cmd "browser"
    Start-Sleep -Seconds 1
    Screendump "screen_drag_06_browser_open.ppm"

    # Step 7: Drag CyberSurf Web Browser by its titlebar
    # Browser initial: x = 75, y = 46, w = 874, h = 660.
    # Grab titlebar at x = 300, y = 58.
    # Drag to x = 150, y = 70.
    Write-Host "[TEST] Step 7: Dragging CyberSurf Web Browser window..." -ForegroundColor Green
    Mouse-Drag 300 58 150 70
    Start-Sleep -Milliseconds 600
    Screendump "screen_drag_07_browser_moved.ppm"

    # Step 8: Resize CyberSurf Web Browser
    # Browser is at x = -75, y = 58 (or clamped to 0..), bottom-right corner
    # Let's drag bottom-right corner
    # Win 3 corner: let's click bookmark first to verify interactivity
    Write-Host "[TEST] Step 8: Clicking [ Demo HTML ] bookmark in CyberSurf..." -ForegroundColor Green
    # win3_x = 75 - 150 = -75 -> clamped to -75, bookmarks at x = -75 + 119 = 44
    # Wait, let's restore browser to default position first by clicking taskbar [Browser]
    # Or let's test resizing
    Mouse-Click 121 72  # Green dot (maximize)
    Start-Sleep -Milliseconds 600
    Screendump "screen_drag_08_browser_max.ppm"

    # Green dot again to restore
    Mouse-Click 121 60
    Start-Sleep -Milliseconds 600
    Screendump "screen_drag_09_browser_restored.ppm"

    # Step 10: Press ESC to exit GUI cleanly
    Write-Host "[TEST] Step 10: Pressing ESC to return to CLI..." -ForegroundColor Green
    Send-Key "esc"
    Start-Sleep -Milliseconds 800
    Screendump "screen_drag_10_cli.ppm"

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
for ppm in glob.glob('screen_drag_*.ppm'):
    png = ppm.replace('.ppm', '.png')
    ppm_to_png(ppm, png)
    os.remove(ppm)
    print(f'Converted {ppm} -> {png}')
"

Write-Host "[TEST] Window Drag & Resize test suite complete!" -ForegroundColor Cyan

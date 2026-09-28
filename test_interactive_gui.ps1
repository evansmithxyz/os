$qemu = "$env:ProgramFiles\qemu\qemu-system-x86_64.exe"
if (-not (Test-Path $qemu)) {
    Write-Host "QEMU not found at $qemu"
    exit 1
}

# Kill any existing QEMU processes
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
        Start-Sleep -Milliseconds 200
    }

    function Screendump($filename) {
        Write-Host "[TEST] Screendump: $filename" -ForegroundColor Yellow
        $null = Send-HMP "screendump $filename"
        Start-Sleep -Milliseconds 400
    }

    # Step 1: Launch GUI Desktop from CLI
    Write-Host "[TEST] Step 1: Launching GUI Desktop ('gui')..." -ForegroundColor Green
    Send-Cmd "gui"
    Start-Sleep -Seconds 1
    Screendump "screen_gui_init.ppm"

    # Step 2: Type in GUI Terminal
    Write-Host "[TEST] Step 2: Typing 'sysinfo' into GUI Terminal..." -ForegroundColor Green
    Send-Cmd "sysinfo"
    Start-Sleep -Milliseconds 300

    Write-Host "[TEST] Step 3: Typing 'ls' into GUI Terminal..." -ForegroundColor Green
    Send-Cmd "ls"
    Start-Sleep -Milliseconds 300

    Write-Host "[TEST] Step 4: Typing 'help' into GUI Terminal..." -ForegroundColor Green
    Send-Cmd "help"
    Start-Sleep -Milliseconds 300
    Screendump "screen_gui_typed.ppm"

    # Step 5: Test mouse buttons via QEMU monitor
    # Mouse starts at (512, 384).
    # Window 0 Red Close button is at (56, 64).
    # dx = 56 - 512 = -456, dy = 64 - 384 = -320.
    Write-Host "[TEST] Step 5: Moving mouse to Window 0 Red Dot and Clicking..." -ForegroundColor Magenta
    $null = Send-HMP "mouse_move -456 -320"
    Start-Sleep -Milliseconds 200
    $null = Send-HMP "mouse_button 1"
    Start-Sleep -Milliseconds 150
    $null = Send-HMP "mouse_button 0"
    Start-Sleep -Milliseconds 400
    Screendump "screen_gui_win0_closed.ppm"

    # Step 6: Click Taskbar [System] pill to restore Window 0
    # Current mouse is at (56, 64).
    # Taskbar [System] pill is at (170, 16).
    # dx = 170 - 56 = +114, dy = 16 - 64 = -48.
    Write-Host "[TEST] Step 6: Clicking Taskbar [System] Pill to reopen..." -ForegroundColor Magenta
    $null = Send-HMP "mouse_move 114 -48"
    Start-Sleep -Milliseconds 200
    $null = Send-HMP "mouse_button 1"
    Start-Sleep -Milliseconds 150
    $null = Send-HMP "mouse_button 0"
    Start-Sleep -Milliseconds 400
    Screendump "screen_gui_win0_reopened.ppm"

    # Step 7: Click Window 1 Green dot to Maximize Terminal
    # Current mouse is at (170, 16).
    # Window 1 Green dot is at X = 505 + 48 = 553, Y = 50 + 14 = 64.
    # dx = 553 - 170 = +383, dy = 64 - 16 = +48.
    Write-Host "[TEST] Step 7: Clicking Window 1 Green Dot to Maximize Terminal..." -ForegroundColor Magenta
    $null = Send-HMP "mouse_move 383 48"
    Start-Sleep -Milliseconds 200
    $null = Send-HMP "mouse_button 1"
    Start-Sleep -Milliseconds 150
    $null = Send-HMP "mouse_button 0"
    Start-Sleep -Milliseconds 400
    Screendump "screen_gui_win1_maximized.ppm"

    # Step 8: Click Window 1 Green dot to Restore (on maximized window at 20+48=68, 45+14=59)
    # Current mouse is at (553, 64).
    # Target is (68, 59): dx = 68 - 553 = -485, dy = 59 - 64 = -5.
    Write-Host "[TEST] Step 8: Clicking Green Dot again to Restore..." -ForegroundColor Magenta
    $null = Send-HMP "mouse_move -485 -5"
    Start-Sleep -Milliseconds 200
    $null = Send-HMP "mouse_button 1"
    Start-Sleep -Milliseconds 150
    $null = Send-HMP "mouse_button 0"
    Start-Sleep -Milliseconds 400
    Screendump "screen_gui_win1_restored.ppm"

    # Step 9: Return to CLI with ESC
    Write-Host "[TEST] Step 9: Pressing ESC to return to CLI..." -ForegroundColor Cyan
    Send-Key "esc"
    Start-Sleep -Seconds 1
    Screendump "screen_gui_cli_restored.ppm"

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
    'screen_gui_init.ppm',
    'screen_gui_typed.ppm',
    'screen_gui_win0_closed.ppm',
    'screen_gui_win0_reopened.ppm',
    'screen_gui_win1_maximized.ppm',
    'screen_gui_win1_restored.ppm',
    'screen_gui_cli_restored.ppm'
]
for f in files:
    png = f.replace('.ppm', '.png')
    if os.path.exists(f):
        ppm_to_png(f, png)
"
Write-Host "[TEST] Interactive GUI verification complete!" -ForegroundColor Green

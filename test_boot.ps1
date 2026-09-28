$qemu = "$env:ProgramFiles\qemu\qemu-system-x86_64.exe"
if (-not (Test-Path $qemu)) {
    Write-Host "QEMU not found at $qemu"
    exit 1
}

# Clean any existing files
if (Test-Path "screen.ppm") { Remove-Item "screen.ppm" -Force }
if (Test-Path "screen.bmp") { Remove-Item "screen.bmp" -Force }
if (Test-Path "qemu_net.pcap") { Remove-Item "qemu_net.pcap" -Force }

# Kill existing QEMU
Get-Process -Name "qemu-system-x86_64" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# Start QEMU with QMP server and packet dumper
$proc = Start-Process -FilePath $qemu -ArgumentList "-drive format=raw,file=bin\os-image.bin -netdev user,id=net0,hostfwd=tcp::8888-:80 -device rtl8139,netdev=net0 -object filter-dump,id=f0,netdev=net0,file=qemu_net.pcap -display none -qmp tcp:127.0.0.1:4444,server,nowait" -PassThru

# Wait 2 seconds for bootloader & kernel initialization
Start-Sleep -Seconds 2

try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 4444)
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.AutoFlush = $true

    # Read greeting
    $null = $reader.ReadLine()

    # Enter QMP capabilities
    $writer.WriteLine('{"execute":"qmp_capabilities"}')
    $null = $reader.ReadLine()

    function Send-Cmd($text) {
        foreach ($ch in $text.ToCharArray()) {
            $k = "$ch"
            if ($ch -eq '.') { $k = "dot" }
            elseif ($ch -eq ' ') { $k = "spc" }
            elseif ($ch -eq '-') { $k = "minus" }
            elseif ($ch -eq '/') { $k = "slash" }

            $writer.WriteLine("{`"execute`":`"human-monitor-command`",`"arguments`":{`"command-line`":`"sendkey $k`"}}")
            $null = $reader.ReadLine()
            Start-Sleep -Milliseconds 30
        }
        $writer.WriteLine('{"execute":"human-monitor-command","arguments":{"command-line":"sendkey ret"}}')
        $null = $reader.ReadLine()
    }

    # Clear screen first
    Send-Cmd "clear"
    Start-Sleep -Milliseconds 500

    # Run curl google.com 80
    Send-Cmd "curl google.com 80"
    Start-Sleep -Seconds 5

    # Dump screen
    $writer.WriteLine('{"execute":"human-monitor-command","arguments":{"command-line":"screendump screen.ppm"}}')
    $null = $reader.ReadLine()
    Start-Sleep -Milliseconds 500

    # Quit QEMU
    $writer.WriteLine('{"execute":"quit"}')
    Start-Sleep -Milliseconds 500

    $client.Close()
} catch {
    Write-Host "Error interacting with QMP: $_"
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

if (Test-Path "screen.ppm") {
    python -c "
with open('screen.ppm', 'rb') as f:
    f.readline()
    while True:
        line = f.readline()
        if not line.startswith(b'#'):
            break
    w, h = map(int, line.split())
    f.readline()
    data = f.read()

row_stride = (w * 3 + 3) & ~3
bmp_data = bytearray(row_stride * h)
for y in range(h):
    src_row = (h - 1 - y) * w * 3
    dst_row = y * row_stride
    for x in range(w):
        bmp_data[dst_row + x * 3] = data[src_row + x * 3 + 2]
        bmp_data[dst_row + x * 3 + 1] = data[src_row + x * 3 + 1]
        bmp_data[dst_row + x * 3 + 2] = data[src_row + x * 3]

import struct
filesize = 54 + len(bmp_data)
hdr = struct.pack('<2sIHHI', b'BM', filesize, 0, 0, 54) + struct.pack('<IIIHHIIIIII', 40, w, h, 1, 24, 0, len(bmp_data), 2835, 2835, 0, 0)
with open('screen.bmp', 'wb') as f:
    f.write(hdr + bmp_data)
"
    Write-Host "Screen converted to screen.bmp successfully!"
} else {
    Write-Host "screendump failed."
}

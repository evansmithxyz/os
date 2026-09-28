import struct
import zlib
import os

def ppm_to_bmp(ppm_path, bmp_path):
    if not os.path.exists(ppm_path):
        return
    with open(ppm_path, 'rb') as f:
        magic = f.readline().strip()
        line = f.readline()
        while line.startswith(b'#'):
            line = f.readline()
        w, h = map(int, line.split())
        maxval = int(f.readline().strip())
        raw_data = f.read()

    row_stride = (w * 3 + 3) & ~3
    bmp_data = bytearray(row_stride * h)
    for y in range(h):
        src_row = (h - 1 - y) * w * 3
        dst_row = y * row_stride
        for x in range(w):
            bmp_data[dst_row + x * 3]     = raw_data[src_row + x * 3 + 2] # B
            bmp_data[dst_row + x * 3 + 1] = raw_data[src_row + x * 3 + 1] # G
            bmp_data[dst_row + x * 3 + 2] = raw_data[src_row + x * 3]     # R

    filesize = 54 + len(bmp_data)
    hdr = struct.pack('<2sIHHI', b'BM', filesize, 0, 0, 54) + struct.pack(
        '<IIIHHIIIIII', 40, w, h, 1, 24, 0, len(bmp_data), 2835, 2835, 0, 0
    )
    with open(bmp_path, 'wb') as f:
        f.write(hdr + bmp_data)
    print(f"Created {bmp_path} ({w}x{h}, {filesize} bytes)")

def ppm_to_png(ppm_path, png_path):
    if not os.path.exists(ppm_path):
        return
    with open(ppm_path, 'rb') as f:
        magic = f.readline().strip()
        line = f.readline()
        while line.startswith(b'#'):
            line = f.readline()
        w, h = map(int, line.split())
        maxval = int(f.readline().strip())
        raw_data = f.read()

    # Raw RGB data to PNG without PIL (pure zlib)
    raw_lines = bytearray()
    for y in range(h):
        raw_lines.append(0) # Filter type 0 (None)
        raw_lines.extend(raw_data[y * w * 3 : (y + 1) * w * 3])

    def png_chunk(chunk_type, data):
        c = chunk_type + data
        crc = zlib.crc32(c) & 0xffffffff
        return struct.pack('>I', len(data)) + c + struct.pack('>I', crc)

    ihdr_data = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0) # 8-bit truecolor RGB
    idat_data = zlib.compress(bytes(raw_lines), 6)

    png_bytes = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', ihdr_data) + png_chunk(b'IDAT', idat_data) + png_chunk(b'IEND', b'')

    with open(png_path, 'wb') as f:
        f.write(png_bytes)
    print(f"Created {png_path} ({w}x{h}, {len(png_bytes)} bytes)")

if __name__ == '__main__':
    for name in ['screen_gui', 'screen_cli']:
        ppm = f'{name}.ppm'
        bmp = f'{name}.bmp'
        png = f'{name}.png'
        ppm_to_bmp(ppm, bmp)
        ppm_to_png(ppm, png)

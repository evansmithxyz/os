#!/usr/bin/env python3
"""Read QEMU screendumps (binary PPM, P6) and write PNGs - standard library only.

    python tools/ppm.py shot.ppm            -> shot.png
    python tools/ppm.py shot.ppm out.png
"""

from __future__ import annotations

import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Image:
    width: int
    height: int
    rgb: bytes  # width * height * 3 bytes, row-major

    def pixel(self, x: int, y: int) -> tuple[int, int, int]:
        i = (y * self.width + x) * 3
        return self.rgb[i], self.rgb[i + 1], self.rgb[i + 2]

    def pixel_hex(self, x: int, y: int) -> int:
        r, g, b = self.pixel(x, y)
        return (r << 16) | (g << 8) | b


def read_ppm(path: str | Path) -> Image:
    data = Path(path).read_bytes()
    fields: list[bytes] = []
    pos = 0
    while len(fields) < 4:  # magic, width, height, maxval (comments allowed)
        while data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end : end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    pos += 1  # single whitespace byte before the pixel data
    if fields[0] != b"P6" or int(fields[3]) != 255:
        raise ValueError(f"{path}: only 8-bit binary PPM (P6) is supported")
    width, height = int(fields[1]), int(fields[2])
    return Image(width, height, data[pos : pos + width * height * 3])


def write_png(image: Image, path: str | Path) -> None:
    def chunk(tag: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload))

    stride = image.width * 3
    raw = b"".join(b"\x00" + image.rgb[y * stride : (y + 1) * stride] for y in range(image.height))
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", image.width, image.height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    Path(path).write_bytes(png)


def ppm_to_png(src: str | Path, dst: str | Path | None = None) -> Path:
    dst = Path(dst) if dst else Path(src).with_suffix(".png")
    write_png(read_ppm(src), dst)
    return dst


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print(__doc__)
        sys.exit(1)
    print(ppm_to_png(*sys.argv[1:]))

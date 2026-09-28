#!/usr/bin/env python3
"""Build and inspect Antigravity OS disk images.

The disk layout (sector numbers) is read from include/layout.inc so the
bootloader, kernel and this tool can never disagree about where things live.

Image layout (see include/layout.inc for the real numbers):

    LBA 0                 stage 1 (MBR)
    STAGE2_LBA ..         stage 2 loader (kernel sector count patched in)
    KERNEL_LBA ..         kernel image (up to KERNEL_MAX_SECTORS)
    FS_SUPERBLOCK_LBA     AntigravityFS superblock ("AFS1")
    FS_INODE_LBA ..       32 inodes x 32 bytes
    FS_DATA_LBA ..        file data (each file is a contiguous run of sectors)

Usage:
    mkimage.py build --stage1 S1 --stage2 S2 --kernel K --out IMG [--rootfs DIR] [--fresh]
    mkimage.py ls IMG
    mkimage.py cat IMG NAME

Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
import os
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAYOUT_INC = ROOT / "include" / "layout.inc"

SECTOR = 512
AFS_MAGIC = b"AFS1"
AFS_MAX_INODES = 32
AFS_INODE_SIZE = 32
AFS_NAME_MAX = 15
AFS_FLAG_ALLOC = 0x01
STAGE2_MAGIC = b"AGS2"
STAGE2_MAGIC_OFFSET = 3
STAGE2_KSECTORS_OFFSET = 7


class ImageError(Exception):
    pass


# ---------------------------------------------------------------------------
# layout.inc parsing
# ---------------------------------------------------------------------------

_EQU = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s+equ\s+([^;]+)", re.IGNORECASE)
_SAFE_EXPR = re.compile(r"^[\sA-Za-z0-9_+\-*/()x]+$")


def parse_inc(path: Path = LAYOUT_INC) -> dict[str, int]:
    """Parse `NAME equ <expr>` lines from a NASM include file."""
    values: dict[str, int] = {}
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        m = _EQU.match(line)
        if not m:
            continue
        name, expr = m.group(1), m.group(2).strip()
        if not _SAFE_EXPR.match(expr):
            raise ImageError(f"{path.name}:{lineno}: unsupported expression {expr!r}")
        expr = re.sub(r"\b(\d+)\b(?!x)", lambda d: str(int(d.group(1))), expr)
        try:
            values[name] = int(eval(expr, {"__builtins__": {}}, dict(values)))  # noqa: S307
        except Exception as exc:  # pragma: no cover - reported to the user
            raise ImageError(f"{path.name}:{lineno}: cannot evaluate {expr!r}: {exc}") from exc
    return values


@dataclass(frozen=True)
class Layout:
    stage2_lba: int
    stage2_sectors: int
    kernel_lba: int
    kernel_max_sectors: int
    superblock_lba: int
    inode_lba: int
    inode_sectors: int
    data_lba: int
    disk_sectors: int

    @classmethod
    def load(cls, path: Path = LAYOUT_INC) -> "Layout":
        v = parse_inc(path)
        layout = cls(
            stage2_lba=v["STAGE2_LBA"],
            stage2_sectors=v["STAGE2_SECTORS"],
            kernel_lba=v["KERNEL_LBA"],
            kernel_max_sectors=v["KERNEL_MAX_SECTORS"],
            superblock_lba=v["FS_SUPERBLOCK_LBA"],
            inode_lba=v["FS_INODE_LBA"],
            inode_sectors=v["FS_INODE_SECTORS"],
            data_lba=v["FS_DATA_LBA"],
            disk_sectors=v["DISK_SECTORS"],
        )
        layout.validate()
        return layout

    def validate(self) -> None:
        if self.stage2_lba + self.stage2_sectors > self.kernel_lba:
            raise ImageError("layout.inc: stage 2 overlaps the kernel")
        if self.kernel_lba + self.kernel_max_sectors > self.superblock_lba:
            raise ImageError("layout.inc: kernel slot overlaps the filesystem")
        if self.inode_lba != self.superblock_lba + 1:
            raise ImageError("layout.inc: FS_INODE_LBA must follow the superblock")
        if self.data_lba != self.inode_lba + self.inode_sectors:
            raise ImageError("layout.inc: FS_DATA_LBA must follow the inode table")
        if self.inode_sectors * SECTOR != AFS_MAX_INODES * AFS_INODE_SIZE:
            raise ImageError("layout.inc: inode table size mismatch")
        if self.disk_sectors <= self.data_lba:
            raise ImageError("layout.inc: DISK_SECTORS leaves no room for data")


# ---------------------------------------------------------------------------
# AntigravityFS
# ---------------------------------------------------------------------------

@dataclass
class Inode:
    name: str
    size: int
    lba: int
    sectors: int
    flags: int

    @classmethod
    def unpack(cls, raw: bytes) -> "Inode":
        name = raw[:16].split(b"\0", 1)[0].decode("ascii", "replace")
        size, lba, sectors, flags = struct.unpack_from("<IHHB", raw, 16)
        return cls(name, size, lba, sectors, flags)

    def pack(self) -> bytes:
        raw = bytearray(AFS_INODE_SIZE)
        name = self.name.encode("ascii")
        raw[: len(name)] = name
        struct.pack_into("<IHHB", raw, 16, self.size, self.lba, self.sectors, self.flags)
        return bytes(raw)


def fs_superblock(layout: Layout) -> bytes:
    sb = bytearray(SECTOR)
    sb[0:4] = AFS_MAGIC
    struct.pack_into("<IIII", sb, 4, layout.disk_sectors, layout.inode_lba, layout.data_lba, AFS_MAX_INODES)
    return bytes(sb)


def fs_is_compatible(image: bytes, layout: Layout) -> bool:
    """True if `image` holds an AFS volume with exactly this layout."""
    off = layout.superblock_lba * SECTOR
    if len(image) < layout.disk_sectors * SECTOR:
        return False
    return image[off : off + SECTOR][:20] == fs_superblock(layout)[:20]


def fs_read_inodes(image: bytes, layout: Layout) -> list[Inode]:
    base = layout.inode_lba * SECTOR
    return [
        Inode.unpack(image[base + i * AFS_INODE_SIZE : base + (i + 1) * AFS_INODE_SIZE])
        for i in range(AFS_MAX_INODES)
    ]


def fs_format(image: bytearray, layout: Layout, files: list[tuple[str, bytes]]) -> None:
    """Write a fresh AFS volume containing `files` into `image`."""
    if len(files) > AFS_MAX_INODES:
        raise ImageError(f"too many files for AFS ({len(files)} > {AFS_MAX_INODES})")
    start = layout.superblock_lba * SECTOR
    image[start : layout.disk_sectors * SECTOR] = bytes(layout.disk_sectors * SECTOR - start)
    image[start : start + SECTOR] = fs_superblock(layout)

    next_lba = layout.data_lba
    inode_base = layout.inode_lba * SECTOR
    for index, (name, data) in enumerate(files):
        if not name or len(name) > AFS_NAME_MAX or not name.isascii():
            raise ImageError(f"invalid AFS file name {name!r} (1-{AFS_NAME_MAX} ASCII chars)")
        sectors = max(1, -(-len(data) // SECTOR))
        if sectors > 0xFFFF or next_lba + sectors > layout.disk_sectors:
            raise ImageError(f"not enough space on the AFS volume for {name!r}")
        image[next_lba * SECTOR : next_lba * SECTOR + len(data)] = data
        inode = Inode(name, len(data), next_lba, sectors, AFS_FLAG_ALLOC)
        image[inode_base + index * AFS_INODE_SIZE : inode_base + (index + 1) * AFS_INODE_SIZE] = inode.pack()
        next_lba += sectors


def rootfs_files(rootfs: Path | None) -> list[tuple[str, bytes]]:
    if rootfs is None or not rootfs.is_dir():
        return []
    files = []
    for path in sorted(rootfs.iterdir()):
        if path.is_file() and not path.name.startswith("."):
            data = path.read_bytes().replace(b"\r\n", b"\n")
            files.append((path.name, data))
    return files


# ---------------------------------------------------------------------------
# Image assembly
# ---------------------------------------------------------------------------

@dataclass
class BuildResult:
    image: Path
    kernel_bytes: int
    kernel_sectors: int
    kernel_max_sectors: int
    fs_preserved: bool
    files: list[str]


def build_image(
    stage1: Path,
    stage2: Path,
    kernel: Path,
    out: Path,
    rootfs: Path | None = None,
    fresh: bool = False,
    layout: Layout | None = None,
) -> BuildResult:
    layout = layout or Layout.load()

    s1 = stage1.read_bytes()
    if len(s1) != SECTOR or s1[510:512] != b"\x55\xAA":
        raise ImageError(f"{stage1}: must be exactly 512 bytes ending in 0x55AA")

    s2 = bytearray(stage2.read_bytes())
    if s2[STAGE2_MAGIC_OFFSET : STAGE2_MAGIC_OFFSET + 4] != STAGE2_MAGIC:
        raise ImageError(f"{stage2}: missing 'AGS2' signature at offset {STAGE2_MAGIC_OFFSET}")
    if len(s2) > layout.stage2_sectors * SECTOR:
        raise ImageError(f"{stage2}: {len(s2)} bytes exceeds {layout.stage2_sectors} sectors")

    k = kernel.read_bytes()
    k_sectors = max(1, -(-len(k) // SECTOR))
    if k_sectors > layout.kernel_max_sectors:
        raise ImageError(
            f"kernel is {len(k)} bytes ({k_sectors} sectors) but the slot holds "
            f"{layout.kernel_max_sectors} sectors - raise KERNEL_MAX_SECTORS in include/layout.inc"
        )
    struct.pack_into("<H", s2, STAGE2_KSECTORS_OFFSET, k_sectors)

    image = bytearray(layout.disk_sectors * SECTOR)
    image[0:SECTOR] = s1
    image[layout.stage2_lba * SECTOR : layout.stage2_lba * SECTOR + len(s2)] = s2
    image[layout.kernel_lba * SECTOR : layout.kernel_lba * SECTOR + len(k)] = k

    preserved = False
    if not fresh and out.exists():
        old = out.read_bytes()
        if fs_is_compatible(old, layout):
            start = layout.superblock_lba * SECTOR
            image[start:] = old[start : layout.disk_sectors * SECTOR]
            preserved = True
    if not preserved:
        fs_format(image, layout, rootfs_files(rootfs))

    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(out.suffix + ".tmp")
    tmp.write_bytes(image)
    os.replace(tmp, out)

    names = [i.name for i in fs_read_inodes(image, layout) if i.flags & AFS_FLAG_ALLOC]
    return BuildResult(out, len(k), k_sectors, layout.kernel_max_sectors, preserved, names)


def read_file(image: bytes, name: str, layout: Layout | None = None) -> bytes:
    layout = layout or Layout.load()
    for inode in fs_read_inodes(image, layout):
        if inode.flags & AFS_FLAG_ALLOC and inode.name == name:
            off = inode.lba * SECTOR
            return image[off : off + inode.size]
    raise FileNotFoundError(name)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cmd_build(args: argparse.Namespace) -> int:
    result = build_image(
        Path(args.stage1), Path(args.stage2), Path(args.kernel), Path(args.out),
        Path(args.rootfs) if args.rootfs else None, args.fresh,
    )
    pct = 100.0 * result.kernel_sectors / result.kernel_max_sectors
    print(f"image  : {result.image}")
    print(f"kernel : {result.kernel_bytes} bytes, {result.kernel_sectors}/{result.kernel_max_sectors} sectors ({pct:.1f}% of slot)")
    print(f"afs    : {'preserved existing volume' if result.fs_preserved else 'formatted from rootfs'} -> {', '.join(result.files) or '(empty)'}")
    return 0


def _cmd_ls(args: argparse.Namespace) -> int:
    layout = Layout.load()
    image = Path(args.image).read_bytes()
    if not fs_is_compatible(image, layout):
        print("no AFS volume with the current layout found", file=sys.stderr)
        return 1
    for inode in fs_read_inodes(image, layout):
        if inode.flags & AFS_FLAG_ALLOC:
            print(f"{inode.name:<16} {inode.size:>6} bytes  lba {inode.lba}  sectors {inode.sectors}")
    return 0


def _cmd_cat(args: argparse.Namespace) -> int:
    sys.stdout.buffer.write(read_file(Path(args.image).read_bytes(), args.name))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="assemble a bootable disk image")
    b.add_argument("--stage1", required=True)
    b.add_argument("--stage2", required=True)
    b.add_argument("--kernel", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--rootfs", help="directory whose files seed a fresh AFS volume")
    b.add_argument("--fresh", action="store_true", help="reformat AFS even if the old image has one")
    b.set_defaults(func=_cmd_build)

    ls = sub.add_parser("ls", help="list files on an image's AFS volume")
    ls.add_argument("image")
    ls.set_defaults(func=_cmd_ls)

    cat = sub.add_parser("cat", help="print a file from an image's AFS volume")
    cat.add_argument("image")
    cat.add_argument("name")
    cat.set_defaults(func=_cmd_cat)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (ImageError, FileNotFoundError) as exc:
        print(f"mkimage: error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

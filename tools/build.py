#!/usr/bin/env python3
"""Antigravity OS build tool - works the same on Linux, WSL, macOS and Windows.

    python tools/build.py              build build/os.img (keeps files on the AFS disk)
    python tools/build.py --fresh      rebuild and reformat the disk from rootfs/
    python tools/build.py run          build, then boot in QEMU (window + serial in this terminal)
    python tools/build.py run --headless   no window: the serial console IS the terminal
    python tools/build.py test [-k NAME]   build and run the automated QEMU tests
    python tools/build.py debug        boot paused, waiting for gdb on localhost:1234
    python tools/build.py sym 0x1234   which kernel function contains an address
    python tools/build.py size         kernel and .bss usage vs. their limits
    python tools/build.py clean        delete build/

Environment overrides: NASM=/path/to/nasm  QEMU=/path/to/qemu-system-x86_64
Only the Python standard library is needed (Python 3.8+).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
IMAGE = BUILD / "os.img"
KERNEL_MAP = BUILD / "kernel.map"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mkimage  # noqa: E402

WINDOWS_NASM = [
    Path(os.environ.get("LOCALAPPDATA", "")) / "bin" / "NASM" / "nasm.exe",
    Path(os.environ.get("LOCALAPPDATA", "")) / "bin" / "nasm.exe",
    Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "NASM" / "nasm.exe",
    Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "NASM" / "nasm.exe",
    Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "NASM" / "nasm.exe",
]
EXTRA_QEMU = [
    Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "qemu" / "qemu-system-x86_64.exe",
    Path("/opt/homebrew/bin/qemu-system-x86_64"),
    Path("/usr/local/bin/qemu-system-x86_64"),
]


class BuildError(Exception):
    pass


def _find_tool(env: str, name: str, extra: list[Path], hint: str) -> str:
    if os.environ.get(env):
        return os.environ[env]
    found = shutil.which(name)
    if found:
        return found
    for path in extra:
        if path.is_file():
            return str(path)
    raise BuildError(f"{name} not found. {hint}\n(or set {env}=/path/to/{name})")


def find_nasm() -> str:
    return _find_tool(
        "NASM", "nasm", WINDOWS_NASM,
        "Install it: winget install NASM.NASM | sudo apt install nasm | brew install nasm",
    )


def find_qemu() -> str:
    return _find_tool(
        "QEMU", "qemu-system-x86_64", EXTRA_QEMU,
        "Install it: winget install SoftwareFreedomConservancy.QEMU | "
        "sudo apt install qemu-system-x86 | brew install qemu",
    )


def _nasm(nasm: str, source: Path, output: Path, includes: list[Path], listing: Path | None = None) -> None:
    cmd = [nasm, "-f", "bin", "-Werror=label-orphan"]
    for inc in includes:
        cmd += ["-i", str(inc) + os.sep]
    cmd += [str(source), "-o", str(output)]
    if listing:
        cmd += ["-l", str(listing)]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise BuildError(f"nasm failed for {source.relative_to(ROOT)}:\n{result.stderr.strip()}")
    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr)


def read_map(path: Path = KERNEL_MAP) -> dict[str, int]:
    """Symbols from the NASM map file: name -> address."""
    symbols: dict[str, int] = {}
    if not path.exists():
        return symbols
    in_symbols = False
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("-- Symbols"):
            in_symbols = True
            continue
        if not in_symbols:
            continue
        # section symbols are "Real  Virtual  Name"; constants are "Value  Name"
        m = re.match(r"^([0-9A-Fa-f]+)\s+([0-9A-Fa-f]+)\s+([A-Za-z_.$?][\w.$?@]*)$", line.strip())
        if m:
            symbols[m.group(3)] = int(m.group(2), 16)
    return symbols


def strip_js(source: Path, output: Path) -> None:
    """The kernel's JavaScript (incbin) without comment lines, indentation and
    blank lines. Only whole-line // comments go: the rest of a line is kept."""
    lines = []
    for line in source.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("//"):
            lines.append(line)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def build(fresh: bool = False, image: Path = IMAGE, listing: bool = False, quiet: bool = False) -> Path:
    nasm = find_nasm()
    BUILD.mkdir(exist_ok=True)
    include = ROOT / "include"
    for js in (ROOT / "kernel" / "js").glob("*.js"):
        strip_js(js, BUILD / "js" / js.name)
    _nasm(nasm, ROOT / "boot" / "stage1.asm", BUILD / "stage1.bin", [include, ROOT / "boot"])
    _nasm(nasm, ROOT / "boot" / "stage2.asm", BUILD / "stage2.bin", [include, ROOT / "boot"])
    # (BUILD first: incbin "js/prelude.js" is the stripped copy)
    _nasm(nasm, ROOT / "kernel" / "kernel.asm", BUILD / "kernel.bin", [BUILD, include, ROOT / "kernel"],
          BUILD / "kernel.lst" if listing else None)

    symbols = read_map()
    values = mkimage.parse_inc(ROOT / "include" / "memmap.inc")
    bss = symbols.get("bss_end", 0) - symbols.get("bss_start", 0)
    if bss > values["KERNEL_BSS_MAX"]:
        raise BuildError(f".bss is {bss} bytes, more than KERNEL_BSS_MAX ({values['KERNEL_BSS_MAX']}) "
                         "in include/memmap.inc")

    try:
        result = mkimage.build_image(
            BUILD / "stage1.bin", BUILD / "stage2.bin", BUILD / "kernel.bin", image,
            rootfs=ROOT / "rootfs", fresh=fresh,
        )
    except mkimage.ImageError as exc:
        raise BuildError(str(exc)) from exc
    if not quiet:
        pct = 100.0 * result.kernel_sectors / result.kernel_max_sectors
        print(f"kernel : {result.kernel_bytes:,} bytes = {pct:.1f}% of the "
              f"{result.kernel_max_sectors * 512 // 1024} KB slot, .bss {bss // 1024} KB")
        fs = "kept existing files" if result.fs_preserved else "formatted from rootfs/"
        print(f"disk   : {image.relative_to(ROOT)} (AFS {fs}: {', '.join(result.files) or 'empty'})")
    return image


def qemu_args(image: Path = IMAGE, *, headless: bool = False, net: bool = True, memory: str = "256M",
              serial: str | None = None, qmp: str | None = None, web_port: int = 8888,
              extra: list[str] | None = None) -> list[str]:
    """Standard QEMU command line. `serial` / `qmp` are chardev specs (tests use TCP).
    Host port `web_port` is forwarded to guest port 80 (for `tcplisten`)."""
    args = [
        find_qemu(),
        "-m", memory,
        "-drive", f"format=raw,file={image},if=ide,index=0",
        "-vga", "std",
        "-no-reboot",                               # triple fault -> QEMU exits instead of looping
        "-d", "cpu_reset,guest_errors", "-D", str(BUILD / "qemu.log"),
    ]
    if net:
        args += ["-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{web_port}-:80",
                 "-device", "rtl8139,netdev=net0"]
    if headless:
        args += ["-display", "none"]
    if serial is not None:
        args += ["-serial", serial]
    elif headless:
        args += ["-serial", "mon:stdio"]            # Ctrl+A X quits
    else:
        args += ["-serial", "stdio"]
    if qmp:
        args += ["-qmp", qmp]
    return args + (extra or [])


def cmd_run(args: argparse.Namespace) -> int:
    extra = []
    if args.kvm:
        if not os.access("/dev/kvm", os.R_OK | os.W_OK):
            raise BuildError("--kvm needs read/write access to /dev/kvm. On Linux/WSL run\n"
                             "  sudo usermod -aG kvm $USER\n"
                             "then restart the shell (on WSL: `wsl --shutdown` from Windows), or drop --kvm.")
        extra += ["-accel", "kvm", "-cpu", "host"]
    build(fresh=args.fresh)
    cmd = qemu_args(headless=args.headless, net=not args.no_net, memory=args.memory, extra=extra)
    if args.headless:
        print("Serial console below. Quit QEMU with Ctrl+A then X.")
    print(" ".join(cmd))
    return subprocess.call(cmd)


def cmd_debug(args: argparse.Namespace) -> int:
    build()
    cmd = qemu_args(headless=args.headless, extra=["-s", "-S"])
    print("QEMU is paused and waiting for a debugger:")
    print("  gdb -ex 'target remote localhost:1234' -ex 'set architecture i386:x86-64'")
    print("  (break *0x10000 for kernel_entry; symbols are in build/kernel.map)")
    return subprocess.call(cmd)


def cmd_sym(args: argparse.Namespace) -> int:
    symbols = read_map()
    if not symbols:
        print("build/kernel.map not found - build first", file=sys.stderr)
        return 1
    addr = int(args.address, 0)
    best = max(((a, n) for n, a in symbols.items() if a <= addr), default=None)
    if best is None:
        print(f"{addr:#x}: before the first kernel symbol")
        return 1
    base, name = best
    print(f"{addr:#x} = {name} + {addr - base:#x}")
    return 0


def cmd_size(_: argparse.Namespace) -> int:
    build(quiet=True)
    symbols = read_map()
    layout = mkimage.parse_inc(ROOT / "include" / "layout.inc")
    mem = mkimage.parse_inc(ROOT / "include" / "memmap.inc")
    image = (BUILD / "kernel.bin").stat().st_size
    slot = layout["KERNEL_MAX_SECTORS"] * 512
    bss = symbols["bss_end"] - symbols["bss_start"]
    print(f"kernel image : {image:>8,} / {slot:>9,} bytes ({100 * image / slot:5.1f}%)")
    print(f"kernel .bss  : {bss:>8,} / {mem['KERNEL_BSS_MAX']:>9,} bytes ({100 * bss / mem['KERNEL_BSS_MAX']:5.1f}%)")
    return 0


def cmd_test(args: argparse.Namespace) -> int:
    build(quiet=True)
    cmd = [sys.executable, "-m", "unittest", "discover", "-s", str(ROOT / "tests"), "-t", str(ROOT), "-v"]
    if args.k:
        cmd += ["-k", args.k]
    return subprocess.call(cmd, cwd=ROOT)


def cmd_clean(_: argparse.Namespace) -> int:
    shutil.rmtree(BUILD, ignore_errors=True)
    print("removed build/")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fresh", action="store_true", help="reformat the AFS disk from rootfs/")
    parser.add_argument("--listing", action="store_true", help="also write build/kernel.lst")
    sub = parser.add_subparsers(dest="cmd")

    run = sub.add_parser("run", help="build and boot in QEMU")
    run.add_argument("--headless", action="store_true", help="no window; serial console in this terminal")
    run.add_argument("--fresh", action="store_true", help="reformat the AFS disk from rootfs/")
    run.add_argument("--no-net", action="store_true", help="no network card")
    run.add_argument("--kvm", action="store_true", help="use KVM acceleration (Linux)")
    run.add_argument("-m", "--memory", default="256M")
    run.set_defaults(func=cmd_run)

    dbg = sub.add_parser("debug", help="boot paused for gdb on :1234")
    dbg.add_argument("--headless", action="store_true")
    dbg.set_defaults(func=cmd_debug)

    sym = sub.add_parser("sym", help="look up a kernel address (e.g. a panic RIP)")
    sym.add_argument("address")
    sym.set_defaults(func=cmd_sym)

    sub.add_parser("size", help="kernel and .bss usage").set_defaults(func=cmd_size)

    test = sub.add_parser("test", help="run the QEMU test suite")
    test.add_argument("-k", help="only tests whose name contains this")
    test.set_defaults(func=cmd_test)

    sub.add_parser("clean", help="delete build/").set_defaults(func=cmd_clean)

    args = parser.parse_args(argv)
    try:
        if args.cmd is None:
            build(fresh=args.fresh, listing=args.listing)
            return 0
        return args.func(args)
    except BuildError as exc:
        print(f"build: error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

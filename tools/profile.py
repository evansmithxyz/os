#!/usr/bin/env python3
"""Profile the OS: a flat profile of where the kernel spends its time.

    python tools/profile.py "for (var i = 0; i < 1e6; i++) {}"
    python tools/profile.py bench/core.js [more.js ...]   (files are copied onto the disk)
    python tools/profile.py --cmd "browser https://example.com/" --until "browser text:"

It boots a fresh image and samples the interrupted RIP every millisecond (the
timer writes them to PROF_ADDR): `js -p ...` for JavaScript, or `prof on`, a
shell command and its output --until for anything else. The samples come out
through the QEMU monitor and are counted per routine with build/kernel.map.
Local labels (routine.label) count towards their routine unless --labels.
Build first (tools/build.py).
"""

import argparse
import bisect
import re
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))

from build import read_map  # noqa: E402
from tests.harness import Machine, OUTPUT  # noqa: E402

PROF_ADDR = 0x01C00000


def symbolize(samples, labels):
    symbols = sorted((addr, name) for name, addr in read_map().items() if 0x10000 <= addr < 0x100000)
    addrs = [a for a, _ in symbols]
    counts = Counter()
    for rip in samples:
        i = bisect.bisect_right(addrs, rip) - 1
        name = symbols[i][1] if i >= 0 else "?"
        if not labels:
            name = name.split(".")[0] or name
        counts[name] += 1
    return counts


def report(vm, n, args):
    """The samples out of the machine, counted per routine and printed."""
    dump = OUTPUT / "profile.bin"
    dump.unlink(missing_ok=True)
    reply = vm.hmp(f'pmemsave {PROF_ADDR:#x} {max(n, 1) * 4:#x} "{dump}"')
    for _ in range(50):
        if dump.exists() and dump.stat().st_size >= n * 4:
            break
        time.sleep(0.1)
    else:
        print(f"(the dump failed: {reply!r})")
        return
    data = dump.read_bytes()[: n * 4]
    samples = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]
    counts = symbolize(samples, args.labels)
    print(f"--- {n} samples (1 ms each)")
    for name, c in counts.most_common(args.top):
        print(f"{100.0 * c / max(n, 1):6.1f}%  {c:6}  {name}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", nargs="*", help="JavaScript code, or .js files to run one after another")
    ap.add_argument("--cmd", help="profile this shell command instead")
    ap.add_argument("--until", help="--cmd: the serial output (a regex) that ends the profile")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--labels", action="store_true", help="count local labels separately")
    ap.add_argument("--timeout", type=float, default=600)
    args = ap.parse_args()

    image = OUTPUT / "profile-source.img"
    OUTPUT.mkdir(parents=True, exist_ok=True)
    image.write_bytes((ROOT / "build" / "os.img").read_bytes())
    files = [Path(w) for w in args.what if w.endswith(".js") and Path(w).exists()]
    for f in files:
        subprocess.run([sys.executable, str(ROOT / "tools" / "mkimage.py"), "add", str(image), str(f),
                        "--name", f.name], check=True, capture_output=True)

    vm = Machine("profile", image=image).start()
    try:
        if args.cmd:
            vm.run("prof on")
            vm.send(args.cmd + "\r")
            vm.expect(args.until or "antigravity64> ", timeout=args.timeout, regex=bool(args.until))
            reply = vm.hmp(f"xp /1wx {read_map()['prof_count']:#x}")
            n = int(reply.split(":")[1].split()[0], 16)
            print(f"=== {args.cmd}")
            report(vm, n, args)
            return 0
        for run in [f.name for f in files] or [" ".join(args.what)]:
            out = vm.run(f"js -p {run}", timeout=args.timeout)
            m = re.search(r"js prof samples (\d+)", out)
            text = "\n".join(line for line in out.splitlines() if "[klog]" not in line).strip()
            print(f"=== js {run}\n{text}")
            if m:
                report(vm, int(m.group(1)), args)
            else:
                print("(no profile)")
    finally:
        vm.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())

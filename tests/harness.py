"""QEMU test harness for Antigravity OS.

A `Machine` boots build/os.img (a private copy per test) in a headless QEMU
and gives you two handles:

  * the serial console (COM1). Everything the OS prints is mirrored there and
    everything you send is typed into the shell, so most tests are just
        out = vm.run("ls")
        assert "welcome.txt" in out
  * QMP (QEMU's control socket): real keyboard keys, mouse movement/clicks and
    screenshots for the desktop.

Both sockets are localhost TCP, so this works on Linux, macOS, WSL and Windows.
Artifacts (serial logs, screenshots) go to tests/output/<test name>.*

The kernel also logs desktop events to serial as "[klog] ..." lines (window
opened, workspace switched, ...), which tests can wait for with expect().
"""

from __future__ import annotations

import json
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "tests" / "output"
sys.path.insert(0, str(ROOT / "tools"))

import build as agbuild  # noqa: E402
import ppm  # noqa: E402

PROMPT = "antigravity64> "
BOOT_READY = "System ready."

# QMP qcodes for characters we type with the real keyboard
_QCODES = {
    " ": ["spc"], "\n": ["ret"], "\r": ["ret"], "\t": ["tab"], "-": ["minus"], "=": ["equal"],
    ".": ["dot"], ",": ["comma"], "/": ["slash"], ";": ["semicolon"], "'": ["apostrophe"],
    "[": ["bracket_left"], "]": ["bracket_right"], "\\": ["backslash"], "`": ["grave_accent"],
    "_": ["shift", "minus"], "+": ["shift", "equal"], ":": ["shift", "semicolon"],
    '"': ["shift", "apostrophe"], "?": ["shift", "slash"], "!": ["shift", "1"], "@": ["shift", "2"],
    "#": ["shift", "3"], "$": ["shift", "4"], "%": ["shift", "5"], "^": ["shift", "6"],
    "&": ["shift", "7"], "*": ["shift", "8"], "(": ["shift", "9"], ")": ["shift", "0"],
    "<": ["shift", "comma"], ">": ["shift", "dot"], "{": ["shift", "bracket_left"],
    "}": ["shift", "bracket_right"], "|": ["shift", "backslash"], "~": ["shift", "grave_accent"],
}


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class MachineError(AssertionError):
    pass


class Machine:
    def __init__(self, name: str, *, image: Path | None = None, net: bool = True, memory: str = "256M"):
        self.name = re.sub(r"[^\w.-]", "_", name)
        self.source_image = image or agbuild.IMAGE
        self.net = net
        self.memory = memory
        OUTPUT.mkdir(parents=True, exist_ok=True)
        self.image = OUTPUT / f"{self.name}.img"
        self.log_path = OUTPUT / f"{self.name}.serial.log"
        self.proc: subprocess.Popen | None = None
        self._serial: socket.socket | None = None
        self._qmp: socket.socket | None = None
        self._qmp_file = None
        self._buf = ""
        self._cursor = 0              # expect() searches from here
        self._lock = threading.Lock()
        self._reader: threading.Thread | None = None
        self.mouse = (512, 384)       # where the OS put the pointer (see mouse_init)
        self.web_port = _free_port()  # host port forwarded to guest port 80

    # ------------------------------------------------------------------ lifecycle
    def start(self, wait_ready: bool = True) -> "Machine":
        shutil.copyfile(self.source_image, self.image)
        serial_port, qmp_port = _free_port(), _free_port()
        cmd = agbuild.qemu_args(
            self.image, headless=True, net=self.net, memory=self.memory,
            serial=f"tcp:127.0.0.1:{serial_port},server=on,wait=off",
            qmp=f"tcp:127.0.0.1:{qmp_port},server=on,wait=off",
            web_port=self.web_port,
            extra=["-S"],             # start paused so no serial output is lost
        )
        cmd[cmd.index("-D") + 1] = str(OUTPUT / f"{self.name}.qemu.log")
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self._serial = self._connect(serial_port)
        self._reader = threading.Thread(target=self._read_serial, daemon=True)
        self._reader.start()
        self._qmp = self._connect(qmp_port)
        self._qmp_file = self._qmp.makefile("rw", encoding="utf-8", newline="\n")
        json.loads(self._qmp_file.readline())          # greeting
        self.qmp("qmp_capabilities")
        self.qmp("cont")
        if wait_ready:
            self.expect(BOOT_READY, timeout=20)
            self.expect(PROMPT)
        return self

    def _connect(self, port: int) -> socket.socket:
        deadline = time.time() + 10
        while True:
            try:
                return socket.create_connection(("127.0.0.1", port), timeout=5)
            except OSError:
                if self.proc and self.proc.poll() is not None:
                    raise MachineError(f"QEMU exited: {self.proc.stdout.read().decode(errors='replace')}")
                if time.time() > deadline:
                    raise
                time.sleep(0.05)

    def _read_serial(self) -> None:
        with open(self.log_path, "w", encoding="utf-8", errors="replace") as log:
            while True:
                try:
                    data = self._serial.recv(4096)
                except OSError:
                    return
                if not data:
                    return
                text = data.decode("latin-1").replace("\r", "")
                log.write(text)
                log.flush()
                with self._lock:
                    self._buf += text

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            try:
                self.qmp("quit")
            except Exception:
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        for sock in (self._qmp_file, self._serial, self._qmp):
            if sock:
                try:
                    sock.close()
                except OSError:
                    pass
        if self.proc and self.proc.stdout:
            self.proc.stdout.close()

    def __enter__(self) -> "Machine":
        return self.start()

    def __exit__(self, *exc) -> None:
        self.stop()

    # ------------------------------------------------------------------ serial
    @property
    def output(self) -> str:
        with self._lock:
            return self._buf

    def expect(self, pattern: str, timeout: float = 10.0, regex: bool = False, allow_panic: bool = False) -> str:
        """Wait until `pattern` appears after the last match; return the text up to and including it.
        A kernel panic fails immediately unless allow_panic is set."""
        deadline = time.time() + timeout
        compiled = re.compile(pattern if regex else re.escape(pattern))
        while True:
            with self._lock:
                m = compiled.search(self._buf, self._cursor)
                if m:
                    chunk = self._buf[self._cursor : m.end()]
                    self._cursor = m.end()
                    return chunk
                if not allow_panic and "[PANIC]" in self._buf[self._cursor :]:
                    raise MachineError(f"kernel panic while waiting for {pattern!r}:\n{self._buf[self._cursor:]}")
            if self.proc.poll() is not None:
                raise MachineError(f"QEMU exited while waiting for {pattern!r}.\n{self._tail()}")
            if time.time() > deadline:
                raise MachineError(f"timed out after {timeout}s waiting for {pattern!r}.\n{self._tail()}")
            time.sleep(0.02)

    def _tail(self, n: int = 1500) -> str:
        return "--- serial (last %d chars) ---\n%s" % (n, self.output[-n:])

    def send(self, text: str) -> None:
        """Type text on the serial console (goes to the shell, or the focused GUI window)."""
        self._serial.sendall(text.encode("latin-1"))

    def run(self, command: str, timeout: float = 10.0) -> str:
        """Run a shell command over serial and return its output (without echo and prompt)."""
        self.send(command + "\r")
        chunk = self.expect(PROMPT, timeout=timeout)
        body = chunk[: -len(PROMPT)]
        first_nl = body.find("\n")         # drop the echoed command line
        return body[first_nl + 1 :] if first_nl >= 0 else ""

    # ------------------------------------------------------------------ QMP
    def qmp(self, command: str, **arguments):
        msg = {"execute": command}
        if arguments:
            msg["arguments"] = arguments
        self._qmp_file.write(json.dumps(msg) + "\n")
        self._qmp_file.flush()
        while True:
            reply = json.loads(self._qmp_file.readline())
            if "event" in reply:
                continue
            if "error" in reply:
                raise MachineError(f"QMP {command}: {reply['error']}")
            return reply.get("return")

    def hmp(self, command_line: str) -> str:
        return self.qmp("human-monitor-command", **{"command-line": command_line})

    def key(self, *qcodes: str, hold_ms: int = 60) -> None:
        """Press a key chord on the real PS/2 keyboard, e.g. key("f2") or key("shift", "f1")."""
        keys = [{"type": "qcode", "data": q} for q in qcodes]
        self.qmp("send-key", keys=keys, **{"hold-time": hold_ms})
        time.sleep(0.08)

    def type(self, text: str) -> None:
        """Type text on the PS/2 keyboard (slower than send(), but exercises the driver)."""
        for ch in text:
            if ch in _QCODES:
                self.key(*_QCODES[ch])
            elif ch.isupper():
                self.key("shift", ch.lower())
            else:
                self.key(ch)

    # ------------------------------------------------------------------ mouse
    def mouse_to(self, x: int, y: int) -> None:
        """Move the pointer to screen position (x, y) with relative PS/2 motion."""
        dx, dy = x - self.mouse[0], y - self.mouse[1]
        while dx or dy:                       # stay inside one PS/2 packet's range
            sx = max(-120, min(120, dx))
            sy = max(-120, min(120, dy))
            self.hmp(f"mouse_move {sx} {sy}")
            dx, dy = dx - sx, dy - sy
            time.sleep(0.02)
        self.mouse = (x, y)
        time.sleep(0.1)

    def mouse_home(self) -> None:
        """Pin the pointer against the top-left corner so its position is known."""
        for _ in range(12):
            self.hmp("mouse_move -120 -120")
        self.mouse = (0, 0)
        time.sleep(0.1)

    def _press_at(self, x: int, y: int) -> bool:
        """Press the left button; True if the kernel logged the press at (x, y)."""
        self.hmp("mouse_button 1")
        time.sleep(0.12)
        try:
            logged = self.expect(r"gui: press (\d+)", timeout=3, regex=True)
        except MachineError:
            return False
        value = int(re.search(r"(\d+)$", logged).group(1))
        return value == x * 10000 + y

    def mouse_down(self, x: int, y: int) -> None:
        """Move to (x, y) and press, re-homing once if the pointer drifted."""
        self.mouse_to(x, y)
        if not self._press_at(x, y):
            self.hmp("mouse_button 0")
            time.sleep(0.2)
            self.mouse_home()
            self.mouse_to(x, y)
            if not self._press_at(x, y):
                raise MachineError(f"mouse press did not land on ({x}, {y})\n{self._tail()}")

    def click(self, x: int, y: int) -> None:
        self.mouse_down(x, y)
        self.hmp("mouse_button 0")
        time.sleep(0.25)

    def drag(self, x1: int, y1: int, x2: int, y2: int, steps: int = 6) -> None:
        self.mouse_down(x1, y1)
        for i in range(1, steps + 1):
            self.mouse_to(x1 + (x2 - x1) * i // steps, y1 + (y2 - y1) * i // steps)
            time.sleep(0.03)
        self.hmp("mouse_button 0")
        time.sleep(0.25)

    # ------------------------------------------------------------------ screen
    def screenshot(self, label: str) -> ppm.Image:
        """Save tests/output/<test>.<label>.png and return the image for pixel checks."""
        raw = OUTPUT / f"{self.name}.{label}.ppm"
        self.qmp("screendump", filename=str(raw))
        for _ in range(50):                   # QEMU writes the file asynchronously
            if raw.exists() and raw.stat().st_size > 0:
                break
            time.sleep(0.05)
        time.sleep(0.1)
        image = ppm.read_ppm(raw)
        ppm.write_png(image, raw.with_suffix(".png"))
        raw.unlink()
        return image

    def wait_quiet(self, seconds: float = 0.3) -> None:
        time.sleep(seconds)


# ---------------------------------------------------------------------------
# unittest glue
# ---------------------------------------------------------------------------
import unittest  # noqa: E402


class OSTestCase(unittest.TestCase):
    """Base class: `self.vm` is a freshly booted machine for every test.

    Set `shared_vm = True` on a class to boot once and share the machine
    between its tests (faster for read-only shell checks).
    """

    shared_vm = False
    disk_files: dict[str, bytes] = {}   # extra AFS files on the test's disk
    _class_vm: Machine | None = None

    @classmethod
    def _image(cls) -> Path | None:
        if not cls.disk_files:
            return None
        import mkimage  # noqa: E402 (tools/ is on sys.path)
        image = bytearray(agbuild.IMAGE.read_bytes())
        for name, data in cls.disk_files.items():
            mkimage.add_file(image, name, data)
        OUTPUT.mkdir(parents=True, exist_ok=True)
        path = OUTPUT / f"{cls.__name__}.base.img"
        path.write_bytes(image)
        return path

    @classmethod
    def setUpClass(cls) -> None:
        cls._base_image = cls._image()
        if cls.shared_vm:
            cls._class_vm = Machine(cls.__name__, image=cls._base_image).start()

    @classmethod
    def tearDownClass(cls) -> None:
        if cls._class_vm:
            cls._class_vm.stop()
            cls._class_vm = None

    def setUp(self) -> None:
        if self.shared_vm:
            self.vm = self._class_vm
        else:
            self.vm = Machine(self.id().split(".", 1)[-1], image=self._base_image).start()
            self.addCleanup(self.vm.stop)

    def start_gui(self) -> Machine:
        """Start the desktop from the serial shell and wait until it is drawn."""
        self.vm.send("gui\r")
        self.vm.expect("gui: started")
        self.vm.expect(PROMPT)          # the GUI terminal printed its prompt
        time.sleep(0.8)
        self.vm.mouse = (512, 384)      # mouse_init centres the pointer
        return self.vm

"""CPU exceptions end in a readable register dump (and the build tool can
symbolise the faulting address)."""

import subprocess
import sys
import time
import unittest

from tests.harness import ROOT, OSTestCase


class PanicTest(OSTestCase):

    def crash(self, kind: str) -> str:
        self.vm.send(f"crash {kind}\r")
        return self.vm.expect("System halted", allow_panic=True)

    def test_invalid_opcode(self):
        out = self.crash("ud")
        self.assertIn("[PANIC] CPU exception: Invalid Opcode (#UD) (vector 6", out)
        self.assertRegex(out, r"RIP=0x[0-9A-F]{16}")

    def test_general_protection(self):
        self.assertIn("General Protection Fault (#GP)", self.crash("gp"))

    def test_page_fault_reports_cr2(self):
        out = self.crash("pf")
        self.assertIn("Page Fault (#PF)", out)
        self.assertIn("CR2=0x0000008000000000", out)

    def test_divide_error(self):
        self.assertIn("Divide Error (#DE)", self.crash("de"))

    def test_rip_resolves_to_the_crash_command(self):
        out = self.crash("ud")
        rip = out.split("RIP=")[1].split()[0]
        sym = subprocess.run([sys.executable, str(ROOT / "tools" / "build.py"), "sym", rip],
                             capture_output=True, text=True, check=True).stdout
        self.assertIn("cmd_crash", sym)

    def test_panic_inside_desktop_returns_to_text_mode(self):
        self.start_gui()
        self.vm.send("crash gp\r")      # typed into the GUI terminal
        self.vm.expect("General Protection Fault", allow_panic=True)
        time.sleep(0.5)
        image = self.vm.screenshot("panic")
        self.assertEqual((image.width, image.height), (720, 400), "should be back in 80x25 text mode")


if __name__ == "__main__":
    unittest.main()

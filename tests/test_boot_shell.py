"""Boot, shell basics, command table, history and completion (serial console)."""

import datetime
import time
import unittest

from tests.harness import PROMPT, OSTestCase


class BootTest(OSTestCase):
    shared_vm = True

    def test_boot_messages(self):
        out = self.vm.output
        self.assertIn("AGOS stage2: loading kernel", out)
        self.assertIn("AGOS stage2: entering long mode", out)
        self.assertRegex(out, r"\[BOOT\] Memory: \d+ MB usable")
        self.assertRegex(out, r"\[BOOT\] Kernel: \d+ KB of 1024 KB slot")
        self.assertIn("[FS] AntigravityFS mounted.", out)
        self.assertIn("[NET] RTL8139 NIC", out)

    def test_memory_detected_from_e820(self):
        out = self.vm.run("mem")
        self.assertIn("BIOS E820 memory map:", out)
        self.assertIn("usable", out)
        # QEMU was started with -m 256M
        self.assertRegex(out, r"Usable total:\s+25\d MB")

    def test_kernel_loaded_above_1mb(self):
        """Stage 2 copies the kernel past real mode's 1 MB limit (unreal mode)."""
        out = self.vm.run("mem")
        self.assertRegex(out, r"Kernel image:\s+0x0+100000 - 0x0+1[0-9A-Fa-f]{5}\s+\(\d+ KB of 1024 KB\)")
        self.assertRegex(out, r"Kernel \.bss:\s+0x0+200000 - ")
        self.assertRegex(out, r"Stack top:\s+0x0+400000")

    def test_sysinfo(self):
        out = self.vm.run("sysinfo")
        self.assertIn("Antigravity OS", out)
        self.assertIn("CPU:", out)
        self.assertIn("10.0.2.15", out)

    def test_cpu(self):
        out = self.vm.run("cpu")
        self.assertRegex(out, r"Vendor:\s+(GenuineIntel|AuthenticAMD)")
        self.assertIn("Long mode:  active", out)

    def test_date_is_host_utc(self):
        """QEMU's CMOS clock starts at the host's UTC time (certificates depend on it)."""
        out = self.vm.run("date").strip()
        shown = datetime.datetime.strptime(out, "%Y-%m-%d %H:%M:%S UTC").replace(tzinfo=datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        self.assertLess(abs((now - shown).total_seconds()), 120, out)

    def test_uptime_advances(self):
        first = int(self.vm.run("uptime").split("(")[1].split()[0])
        time.sleep(0.3)
        second = int(self.vm.run("uptime").split("(")[1].split()[0])
        self.assertGreater(second - first, 200, "PIT should tick at ~1000 Hz")

    def test_regs_shows_long_mode(self):
        out = self.vm.run("regs")
        efer = int(out.split("EFER   = ")[1].split()[0], 16)
        self.assertTrue(efer & (1 << 10), "EFER.LMA must be set")


class ShellTest(OSTestCase):
    shared_vm = True

    def test_help_lists_every_section(self):
        out = self.vm.run("help")
        for heading in ("Files", "Network", "System", "Desktop"):
            self.assertIn(heading, out)
        for command in ("ls", "cat <file>", "ping <host>", "curl [-k] <url>", "gui", "browser [url]"):
            self.assertIn(command, out)
        self.assertNotIn("crash", out, "hidden commands must not be listed")

    def test_unknown_command(self):
        self.assertIn("Unknown command: frobnicate", self.vm.run("frobnicate"))

    def test_echo(self):
        self.assertEqual(self.vm.run("echo hello   world").strip(), "hello   world")

    def test_aliases(self):
        self.assertEqual(self.vm.run("dir"), self.vm.run("ls"))

    def test_desktop_only_command_in_text_mode(self):
        self.assertIn("only works in the desktop", self.vm.run("ws 2"))

    def test_history_with_up_arrow(self):
        self.vm.run("echo first-entry")
        self.vm.key("up")               # real PS/2 arrow key
        self.vm.key("ret")
        out = self.vm.expect(PROMPT)
        self.assertIn("first-entry", out)

    def test_tab_completes_command(self):
        self.vm.send("upt\t")
        self.vm.expect("uptime ")
        self.vm.send("\r")
        self.assertIn("ticks at 1000 Hz", self.vm.expect(PROMPT))

    def test_tab_completes_file_name(self):
        self.vm.send("cat welc\t")
        self.vm.expect("welcome.txt ")
        self.vm.send("\r")
        self.assertIn("Welcome to Antigravity OS", self.vm.expect(PROMPT))

    def test_ctrl_c_discards_line(self):
        self.vm.send("echo never-run\x03")
        self.vm.expect("^C")
        self.vm.expect(PROMPT)
        self.assertEqual(self.vm.run("echo after").strip(), "after")


if __name__ == "__main__":
    unittest.main()

"""AntigravityFS: listing, reading, writing, deleting and persistence on disk."""

import sys
import unittest

from tests.harness import ROOT, Machine, OSTestCase

sys.path.insert(0, str(ROOT / "tools"))
import mkimage  # noqa: E402


class FileSystemTest(OSTestCase):

    def test_ls_shows_rootfs_files(self):
        out = self.vm.run("ls")
        self.assertIn("welcome.txt", out)
        self.assertIn("readme.txt", out)

    def test_cat(self):
        self.assertIn("Persistent storage powered by AntigravityFS", self.vm.run("cat welcome.txt"))

    def test_cat_missing_file(self):
        self.assertIn("File not found: nope.txt", self.vm.run("cat nope.txt"))

    def test_write_cat_rm(self):
        self.assertIn("Wrote 11 bytes to notes.txt", self.vm.run("write notes.txt hello world"))
        self.assertEqual(self.vm.run("cat notes.txt").strip(), "hello world")
        self.assertIn("notes.txt", self.vm.run("ls"))
        self.assertIn("Removed notes.txt", self.vm.run("rm notes.txt"))
        self.assertNotIn("notes.txt", self.vm.run("ls"))

    def test_touch_rejects_long_names(self):
        self.assertIn("Could not create", self.vm.run("touch this-name-is-way-too-long.txt"))

    def test_df_counts_files(self):
        before = self.vm.run("df")
        self.vm.run("touch extra.txt")
        after = self.vm.run("df")
        self.assertIn("2 of 32", before)
        self.assertIn("3 of 32", after)

    def test_writes_reach_the_disk_image(self):
        """Data written by the kernel's ATA driver is readable by tools/mkimage.py."""
        self.vm.run("write saved.txt persisted across power off")
        self.vm.stop()
        data = mkimage.read_file(self.vm.image.read_bytes(), "saved.txt")
        self.assertEqual(data, b"persisted across power off")

    def test_files_survive_reboot(self):
        self.vm.run("write keep.txt still here")
        self.vm.stop()
        with Machine(self.vm.name + "_reboot", image=self.vm.image) as second:
            self.assertEqual(second.run("cat keep.txt").strip(), "still here")


if __name__ == "__main__":
    unittest.main()

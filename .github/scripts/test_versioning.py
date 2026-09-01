import tempfile
import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import versioning


class VersioningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "Version.xcconfig"
        self.path.write_text(
            "INPUTPILOT_VERSION = 0.8.16\n"
            "INPUTPILOT_RELEASE = $(INPUTPILOT_VERSION)\n"
            "INPUTPILOT_CHANNEL = stable\n"
            "INPUTPILOT_BUILD = 1\n"
            "MARKETING_VERSION = $(INPUTPILOT_VERSION)\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_reads_shared_version_and_usb_bcd(self):
        self.assertEqual(versioning.project_version(self.path), "0.8.16")
        self.assertEqual(versioning.release_version(self.path), "0.8.16")
        self.assertEqual(versioning.firmware_bcd_literal(self.path), "0x0816")

    def test_beta_release_keeps_numeric_app_version(self):
        self.assertEqual(
            versioning.set_release_version("0.9.0-beta.2", self.path),
            "0.9.0-beta.2",
        )
        self.assertEqual(versioning.project_version(self.path), "0.9.0")
        self.assertEqual(versioning.release_version(self.path), "0.9.0-beta.2")
        self.assertEqual(versioning.firmware_bcd_literal(self.path), "0x0900")
        self.assertIn("INPUTPILOT_CHANNEL = beta", self.path.read_text())

    def test_stable_release_resets_release_alias(self):
        versioning.set_release_version("0.9.0-beta.3", self.path)
        versioning.set_release_version("0.9.0", self.path)
        self.assertEqual(versioning.release_version(self.path), "0.9.0")
        self.assertIn("INPUTPILOT_RELEASE = $(INPUTPILOT_VERSION)", self.path.read_text())
        self.assertIn("INPUTPILOT_CHANNEL = stable", self.path.read_text())

    def test_bumps_only_the_shared_version(self):
        self.assertEqual(versioning.bump_version("patch", self.path), "0.8.17")
        self.assertIn("INPUTPILOT_VERSION = 0.8.17", self.path.read_text())
        self.assertIn("INPUTPILOT_RELEASE = $(INPUTPILOT_VERSION)", self.path.read_text())
        self.assertIn("INPUTPILOT_CHANNEL = stable", self.path.read_text())
        self.assertIn("INPUTPILOT_BUILD = 1", self.path.read_text())

    def test_minor_bump_resets_patch(self):
        self.assertEqual(versioning.bump_version("minor", self.path), "0.9.0")

    def test_rejects_versions_that_do_not_fit_usb_bcd(self):
        self.path.write_text("INPUTPILOT_VERSION = 0.10.0\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            versioning.firmware_bcd_literal(self.path)

    def test_rejects_unrepresentable_bump_before_writing(self):
        self.path.write_text("INPUTPILOT_VERSION = 9.9.99\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            versioning.bump_version("patch", self.path)
        self.assertEqual(self.path.read_text(encoding="utf-8"),
                         "INPUTPILOT_VERSION = 9.9.99\n")


if __name__ == "__main__":
    unittest.main()

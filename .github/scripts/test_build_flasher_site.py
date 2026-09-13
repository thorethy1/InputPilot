#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("build_flasher_site.py")
SPEC = importlib.util.spec_from_file_location("build_flasher_site", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class BuildFlasherSiteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        for name in MODULE.STATIC_FILES:
            (self.source / name).write_text(f"test {name}\n", encoding="utf-8")
        self.logo = self.root / "logo.svg"
        self.logo.write_text("<svg/>\n", encoding="utf-8")
        self.firmware = self.root / MODULE.FIRMWARE_NAME
        self.firmware.write_bytes(b"inputpilot-initial-image")
        self.release_json = self.root / "release.json"
        self.output = self.root / "site"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def release(self, **overrides) -> dict:
        digest = hashlib.sha256(self.firmware.read_bytes()).hexdigest()
        value = {
            "draft": False,
            "prerelease": False,
            "tag_name": "v1.2.3",
            "published_at": "2026-09-13T10:00:00Z",
            "assets": [{
                "name": MODULE.FIRMWARE_NAME,
                "state": "uploaded",
                "size": self.firmware.stat().st_size,
                "digest": f"sha256:{digest}",
            }],
        }
        value.update(overrides)
        return value

    def build(self, release: dict) -> None:
        self.release_json.write_text(json.dumps(release), encoding="utf-8")
        MODULE.build_site(
            self.source, self.output, self.release_json, self.firmware, self.logo
        )

    def test_builds_same_origin_manifest_for_stable_release(self) -> None:
        self.build(self.release())
        manifest = json.loads((self.output / "manifest.json").read_text(encoding="utf-8"))
        metadata = json.loads((self.output / "release.json").read_text(encoding="utf-8"))

        self.assertEqual(manifest["version"], "1.2.3")
        self.assertEqual(manifest["builds"][0]["chipFamily"], "ESP32-S3")
        self.assertEqual(
            manifest["builds"][0]["parts"],
            [{"path": "firmware/InitialFirmware.bin", "offset": 0}],
        )
        self.assertFalse(manifest["new_install_prompt_erase"])
        self.assertEqual(metadata["tag"], "v1.2.3")
        self.assertEqual(
            (self.output / "firmware" / MODULE.FIRMWARE_NAME).read_bytes(),
            self.firmware.read_bytes(),
        )
        self.assertTrue((self.output / ".nojekyll").exists())

    def test_rejects_prerelease(self) -> None:
        with self.assertRaisesRegex(ValueError, "stable release"):
            self.build(self.release(prerelease=True, tag_name="v1.2.3-beta.1"))

    def test_rejects_firmware_with_wrong_digest(self) -> None:
        release = self.release()
        release["assets"][0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.build(release)


if __name__ == "__main__":
    unittest.main()

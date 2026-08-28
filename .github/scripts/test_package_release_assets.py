import hashlib
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


SPEC = importlib.util.spec_from_file_location("package_release_assets", Path(__file__).with_name("package_release_assets.py"))
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


class InitialFlashPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        offsets = [0x0, 0x8000, 0xE000, 0x10000]
        payloads = [b"bootloader", b"partitions", b"boot_app0", b"firmware"]
        entries = []
        merged = bytearray(b"\xff" * (offsets[-1] + len(payloads[-1])))
        for name, offset, payload in zip(package.INITIAL_IMAGE_NAMES, offsets, payloads):
            (self.root / name).write_bytes(payload)
            merged[offset:offset + len(payload)] = payload
            entries.append({"offset": f"0x{offset:04x}", "file": name, "size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()})
        (self.root / "initial-flash.bin").write_bytes(merged)
        (self.root / "initial-flash-manifest.json").write_text(json.dumps({
            "product": "InputPilot", "version": "0.8.0", "board": "esp32-s3-zero-4mb",
            "flashSize": 4194304, "images": entries,
        }))
        (self.root / "flash_args").write_text("0x0 bootloader.bin 0x8000 partitions.bin 0xe000 boot_app0.bin 0x10000 firmware.bin\n")
        (self.root / "README.txt").write_text("initial only")

    def tearDown(self):
        self.temp.cleanup()

    def test_complete_initial_flash_zip(self):
        destination = self.root / "package.zip"
        package.create_initial_flash_zip(self.root, destination)
        with zipfile.ZipFile(destination) as archive:
            self.assertEqual(set(archive.namelist()), set((*package.INITIAL_IMAGE_NAMES, *package.INITIAL_SUPPORT_NAMES, "README.txt")))

    def test_missing_boot_app0_fails(self):
        (self.root / "boot_app0.bin").unlink()
        with self.assertRaises(ValueError):
            package.validate_initial_flash_assets(self.root)

    def test_wrong_offset_or_merged_content_fails(self):
        manifest_path = self.root / "initial-flash-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["images"][2]["offset"] = "0xd000"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            package.validate_initial_flash_assets(self.root)

    def test_ota_copy_publishes_only_image_and_manifest(self):
        firmware = b"firmware"
        digest = hashlib.sha256(firmware).hexdigest()
        (self.root / "firmware.bin").write_bytes(firmware)
        (self.root / "firmware-manifest.json").write_text(json.dumps({
            "version": "0.8.5", "size": len(firmware), "sha256": digest,
        }))
        output = self.root / "public"
        output.mkdir()
        copied = package.copy_ota_assets(self.root, output)
        self.assertEqual({path.name for path in copied}, {"firmware.bin", "firmware-manifest.json"})
        self.assertEqual({path.name for path in output.iterdir()}, {"firmware.bin", "firmware-manifest.json"})


if __name__ == "__main__":
    unittest.main()

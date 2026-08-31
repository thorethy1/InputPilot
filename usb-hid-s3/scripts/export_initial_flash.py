Import("env")

import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path


REPOSITORY = Path(env.subst("$PROJECT_DIR")).resolve().parent
sys.path.insert(0, str(REPOSITORY))
from versioning import project_version  # noqa: E402


PRODUCT = "InputPilot"
BOARD = "esp32-s3-zero-4mb"
FLASH_SIZE = 4 * 1024 * 1024


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def export_initial_flash(source, target, env):
    build_env = env
    build_dir = Path(build_env.subst("$BUILD_DIR"))
    firmware = Path(str(target[0])).resolve()
    images = []

    for offset, source_path in build_env.get("FLASH_EXTRA_IMAGES", []):
        source_image = Path(build_env.subst(str(source_path))).resolve()
        destination = build_dir / source_image.name
        if source_image != destination.resolve():
            shutil.copyfile(source_image, destination)
        images.append((int(str(offset), 0), destination))

    app_offset = build_env.subst("$ESP32_APP_OFFSET")
    if not app_offset:
        raise RuntimeError("PlatformIO did not expose ESP32_APP_OFFSET")
    images.append((int(app_offset, 0), firmware))
    images.sort(key=lambda item: item[0])

    expected_names = {"bootloader.bin", "partitions.bin", "boot_app0.bin", "firmware.bin"}
    actual_names = {path.name for _, path in images}
    if actual_names != expected_names:
        raise RuntimeError(f"unexpected full-flash image set: {sorted(actual_names)}")
    for _, path in images:
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"required full-flash image is missing or empty: {path}")

    version = project_version(REPOSITORY / "Version.xcconfig")
    manifest = {
        "product": PRODUCT,
        "version": version,
        "board": BOARD,
        "flashSize": FLASH_SIZE,
        "images": [
            {
                "offset": f"0x{offset:04x}",
                "file": path.name,
                "size": path.stat().st_size,
                "sha256": digest(path),
            }
            for offset, path in images
        ],
    }
    (build_dir / "initial-flash-manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )

    flash_args = []
    for offset, path in images:
        flash_args.extend((f"0x{offset:x}", path.name))
    (build_dir / "flash_args").write_text(" ".join(flash_args) + "\n", encoding="utf-8")

    merged = build_dir / "initial-flash.bin"
    command = [
        build_env.subst("$PYTHONEXE"), build_env.subst("$UPLOADER"),
        "--chip", "esp32s3", "merge-bin", "--output", str(merged),
    ]
    for offset, path in images:
        command.extend((f"0x{offset:x}", str(path)))
    subprocess.run(command, check=True)
    if not merged.is_file() or merged.stat().st_size == 0:
        raise RuntimeError("esptool did not create initial-flash.bin")
    print(f"InputPilot initial flash: {len(images)} images, {merged.stat().st_size} merged bytes")


env.AddPostAction("$BUILD_DIR/${PROGNAME}.bin", export_initial_flash)

#!/usr/bin/env python3
"""Build the static InputPilot web flasher from a verified stable release."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path


TAG_PATTERN = re.compile(r"^v(?P<version>\d+\.\d+\.\d+)$")
STATIC_FILES = (
    "index.html",
    "styles.css",
    "app.js",
    "en/index.html",
    "assets/inputpilot-logo.svg",
)
FIRMWARE_NAME = "InitialFirmware.bin"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_site(
    source: Path,
    output: Path,
    release_json: Path,
    firmware: Path,
) -> None:
    release = json.loads(release_json.read_text(encoding="utf-8"))
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise ValueError("web flasher requires a published stable release")

    tag = release.get("tag_name", "")
    match = TAG_PATTERN.fullmatch(tag)
    if not match:
        raise ValueError(f"stable release tag must match vMAJOR.MINOR.PATCH, got {tag!r}")
    if not release.get("published_at"):
        raise ValueError("stable release has no publication date")

    assets = [asset for asset in release.get("assets", []) if asset.get("name") == FIRMWARE_NAME]
    if len(assets) != 1:
        raise ValueError(f"expected exactly one {FIRMWARE_NAME} release asset")
    asset = assets[0]
    if asset.get("state") != "uploaded" or asset.get("size") != firmware.stat().st_size:
        raise ValueError("downloaded initial firmware does not match the uploaded release asset")

    actual_digest = sha256(firmware)
    advertised_digest = asset.get("digest", "")
    if advertised_digest != f"sha256:{actual_digest}":
        raise ValueError("downloaded initial firmware SHA-256 does not match GitHub")
    if firmware.stat().st_size <= 0 or firmware.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("initial firmware is empty or exceeds the supported 4 MB flash")

    if output.exists():
        shutil.rmtree(output)
    (output / "assets").mkdir(parents=True)
    (output / "firmware").mkdir()

    for name in STATIC_FILES:
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, destination)
    shutil.copyfile(firmware, output / "firmware" / FIRMWARE_NAME)
    (output / ".nojekyll").touch()

    manifest = {
        "name": "InputPilot",
        "version": match.group("version"),
        "new_install_prompt_erase": False,
        "new_install_improv_wait_time": 0,
        "builds": [
            {
                "chipFamily": "ESP32-S3",
                "improv": False,
                "parts": [{"path": f"firmware/{FIRMWARE_NAME}", "offset": 0}],
            }
        ],
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )

    public_release = {
        "tag": tag,
        "version": match.group("version"),
        "publishedAt": release["published_at"],
        "firmware": {
            "name": FIRMWARE_NAME,
            "size": firmware.stat().st_size,
            "sha256": actual_digest,
        },
    }
    (output / "release.json").write_text(
        json.dumps(public_release, indent=2) + "\n", encoding="utf-8"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release-json", type=Path, required=True)
    parser.add_argument("--firmware", type=Path, required=True)
    args = parser.parse_args()
    build_site(args.source, args.output, args.release_json, args.firmware)


if __name__ == "__main__":
    main()

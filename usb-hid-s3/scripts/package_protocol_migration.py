#!/usr/bin/env python3
"""Validate and package the one-time protocol-v1-to-v2 firmware image."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path


PREFIX = b"INPUTPILOT-META:"
MINIMUM_SIZE = 64 * 1024
OTA_SLOT_SIZE = 0x1E0000
APP_DESCRIPTOR_MAGIC = bytes((0x32, 0x54, 0xCD, 0xAB))
V2_MARKERS = (
    b"secure_protocol_v2",
    b"InputPilot secure protocol v2 client",
    b"InputPilot secure protocol v2 server",
)


def image_metadata(image: bytes) -> dict[str, str]:
    if len(image) < MINIMUM_SIZE:
        raise ValueError("firmware image is too small for the InputPilot 0.8.8 validator")
    if len(image) > OTA_SLOT_SIZE:
        raise ValueError("firmware image exceeds the InputPilot OTA slot")
    if image[0] != 0xE9:
        raise ValueError("firmware image has no ESP32 image header")
    if image[32:36] != APP_DESCRIPTOR_MAGIC:
        raise ValueError("firmware image is not an ESP32 application image")

    offset = 0
    while True:
        offset = image.find(PREFIX, offset)
        if offset < 0:
            raise ValueError("firmware image has no InputPilot metadata")
        start = offset + len(PREFIX)
        end = image.find(b"\0", start)
        offset = start
        if end < 0:
            continue
        try:
            text = image[start:end].decode("utf-8")
            fields: dict[str, str] = {}
            for item in text.split(";"):
                if not item:
                    continue
                key, value = item.split("=", 1)
                if key in fields:
                    raise ValueError(f"duplicate firmware metadata field: {key}")
                fields[key] = value
        except (UnicodeDecodeError, ValueError):
            continue
        required = ("product", "board", "version", "protocol", "otaSchema")
        if all(fields.get(key) for key in required):
            return fields


def validate_migration_image(image: bytes) -> dict[str, str]:
    fields = image_metadata(image)
    if fields["product"] != "InputPilot":
        raise ValueError("firmware metadata targets another product")
    if fields["board"] != "esp32-s3-zero-4mb":
        raise ValueError("firmware metadata targets another board")
    if fields["protocol"] != "1":
        raise ValueError("iOS app 0.8.8 accepts only firmware metadata protocol=1")
    if int(fields["otaSchema"]) > 1:
        raise ValueError("iOS app 0.8.8 accepts only OTA schema 1")
    missing_markers = [marker.decode("ascii") for marker in V2_MARKERS if marker not in image]
    if missing_markers:
        raise ValueError(
            "image does not contain the current protocol-v2 runtime markers: "
            + ", ".join(missing_markers)
        )
    return fields


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--firmware", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    image = args.firmware.read_bytes()
    fields = validate_migration_image(image)
    digest = hashlib.sha256(image).hexdigest()
    args.output.mkdir(parents=True, exist_ok=True)

    destination = args.output / "firmware-migration-v1-to-v2.bin"
    shutil.copyfile(args.firmware, destination)
    (args.output / "firmware-migration-v1-to-v2.sha256").write_text(
        f"{digest}  {destination.name}\n", encoding="utf-8"
    )
    (args.output / "firmware-migration-v1-to-v2.json").write_text(
        json.dumps(
            {
                "product": fields["product"],
                "version": fields["version"],
                "board": fields["board"],
                "protocol": 1,
                "runtimeProtocol": 2,
                "otaSchema": int(fields["otaSchema"]),
                "minimum_app_version": "0.8.8",
                "size": len(image),
                "sha256": digest,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Packaged {destination} ({len(image)} bytes, sha256 {digest})")


if __name__ == "__main__":
    main()

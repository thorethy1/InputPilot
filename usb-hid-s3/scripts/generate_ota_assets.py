#!/usr/bin/env python3
"""Generate deterministic OTA metadata from the built application image."""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY))
from versioning import project_version  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--firmware", type=Path, required=True)
    parser.add_argument("--config", type=Path, default=Path("include/Config.h"))
    parser.add_argument("--version-file", type=Path,
                        default=REPOSITORY / "Version.xcconfig")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    image = args.firmware.read_bytes()
    config = args.config.read_text(encoding="utf-8")
    version = project_version(args.version_file)
    schema = int(re.search(r"#define\s+OTA_SCHEMA_VERSION\s+(\d+)", config).group(1))
    protocol = int(re.search(r"#define\s+OTA_PROTOCOL_VERSION\s+(\d+)", config).group(1))
    digest = hashlib.sha256(image).hexdigest()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "firmware.sha256").write_text(f"{digest}  firmware.bin\n", encoding="utf-8")
    manifest = {
        "product": "InputPilot", "version": version, "board": "esp32-s3-zero-4mb",
        "protocol": protocol, "otaSchema": schema, "size": len(image), "sha256": digest,
    }
    (args.output / "firmware-manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()

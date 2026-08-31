#!/usr/bin/env python3
"""Read and update InputPilot's shared app/firmware version."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


VERSION_PATTERN = re.compile(
    r"(?m)^(INPUTPILOT_VERSION\s*=\s*)(\d+)\.(\d+)\.(\d+)(\s*)$"
)
DEFAULT_VERSION_FILE = Path(__file__).with_name("Version.xcconfig")


def version_parts(path: Path = DEFAULT_VERSION_FILE) -> tuple[int, int, int]:
    text = path.read_text(encoding="utf-8")
    match = VERSION_PATTERN.search(text)
    if not match:
        raise ValueError(f"{path} must contain one INPUTPILOT_VERSION = MAJOR.MINOR.PATCH")
    if len(VERSION_PATTERN.findall(text)) != 1:
        raise ValueError(f"{path} contains more than one INPUTPILOT_VERSION")
    return tuple(int(match.group(index)) for index in (2, 3, 4))


def project_version(path: Path = DEFAULT_VERSION_FILE) -> str:
    return ".".join(str(part) for part in version_parts(path))


def firmware_bcd_literal(path: Path = DEFAULT_VERSION_FILE) -> str:
    major, minor, patch = version_parts(path)
    return firmware_bcd_for_parts(major, minor, patch)


def firmware_bcd_for_parts(major: int, minor: int, patch: int) -> str:
    if major > 9 or minor > 9 or patch > 99:
        raise ValueError("USB bcdDevice supports versions through 9.9.99")
    return f"0x{major}{minor}{patch:02d}"


def bump_version(part: str, path: Path = DEFAULT_VERSION_FILE) -> str:
    major, minor, patch = version_parts(path)
    if part == "major":
        major, minor, patch = major + 1, 0, 0
    elif part == "minor":
        minor, patch = minor + 1, 0
    elif part == "patch":
        patch += 1
    else:
        raise ValueError(f"unsupported version bump: {part}")
    firmware_bcd_for_parts(major, minor, patch)
    new_version = f"{major}.{minor}.{patch}"
    text = path.read_text(encoding="utf-8")
    updated, replacements = VERSION_PATTERN.subn(
        lambda match: f"{match.group(1)}{new_version}{match.group(5)}", text
    )
    if replacements != 1:
        raise ValueError(f"expected one version replacement in {path}, got {replacements}")
    path.write_text(updated, encoding="utf-8")
    return new_version


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("show", "bump", "firmware-bcd"))
    parser.add_argument("part", nargs="?", choices=("major", "minor", "patch"))
    parser.add_argument("--file", type=Path, default=DEFAULT_VERSION_FILE)
    args = parser.parse_args()
    if args.command == "bump":
        if not args.part:
            parser.error("bump requires major, minor, or patch")
        print(bump_version(args.part, args.file))
    elif args.command == "firmware-bcd":
        print(firmware_bcd_literal(args.file))
    else:
        print(project_version(args.file))


if __name__ == "__main__":
    main()

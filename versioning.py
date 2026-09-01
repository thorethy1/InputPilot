#!/usr/bin/env python3
"""Read and update InputPilot's shared app/firmware version."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


VERSION_PATTERN = re.compile(
    r"(?m)^(INPUTPILOT_VERSION\s*=\s*)(\d+)\.(\d+)\.(\d+)(\s*)$"
)
RELEASE_PATTERN = re.compile(
    r"(?m)^(INPUTPILOT_RELEASE\s*=\s*)([^\s]+)(\s*)$"
)
CHANNEL_PATTERN = re.compile(r"(?m)^(INPUTPILOT_CHANNEL\s*=\s*)(stable|beta)(\s*)$")
RELEASE_VERSION_PATTERN = re.compile(
    r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*))?$"
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


def release_version(path: Path = DEFAULT_VERSION_FILE) -> str:
    text = path.read_text(encoding="utf-8")
    match = RELEASE_PATTERN.search(text)
    if not match or match.group(2) == "$(INPUTPILOT_VERSION)":
        return project_version(path)
    value = match.group(2)
    parsed = RELEASE_VERSION_PATTERN.fullmatch(value)
    if not parsed:
        raise ValueError(f"{path} contains an invalid INPUTPILOT_RELEASE")
    core = ".".join(parsed.group(index) for index in (1, 2, 3))
    if core != project_version(path):
        raise ValueError(
            f"INPUTPILOT_RELEASE core {core} does not match INPUTPILOT_VERSION {project_version(path)}"
        )
    return value


def set_release_version(value: str, path: Path = DEFAULT_VERSION_FILE) -> str:
    parsed = RELEASE_VERSION_PATTERN.fullmatch(value)
    if not parsed:
        raise ValueError("release version must match MAJOR.MINOR.PATCH[-PRERELEASE]")
    firmware_bcd_for_parts(*(int(parsed.group(index)) for index in (1, 2, 3)))
    core = ".".join(parsed.group(index) for index in (1, 2, 3))
    text = path.read_text(encoding="utf-8")
    text, replacements = VERSION_PATTERN.subn(
        lambda match: f"{match.group(1)}{core}{match.group(5)}", text
    )
    if replacements != 1:
        raise ValueError(f"expected one INPUTPILOT_VERSION replacement in {path}")
    release_value = value if parsed.group(4) else "$(INPUTPILOT_VERSION)"
    channel = "beta" if parsed.group(4) else "stable"
    if RELEASE_PATTERN.search(text):
        text, replacements = RELEASE_PATTERN.subn(
            lambda match: f"{match.group(1)}{release_value}{match.group(3)}", text
        )
        if replacements != 1:
            raise ValueError(f"expected one INPUTPILOT_RELEASE replacement in {path}")
    else:
        version_line = VERSION_PATTERN.search(text)
        if not version_line:
            raise ValueError(f"{path} has no INPUTPILOT_VERSION")
        text = text[:version_line.end()] + f"\nINPUTPILOT_RELEASE = {release_value}" + text[version_line.end():]
    if CHANNEL_PATTERN.search(text):
        text = CHANNEL_PATTERN.sub(
            lambda match: f"{match.group(1)}{channel}{match.group(3)}", text
        )
    else:
        release_line = RELEASE_PATTERN.search(text)
        if not release_line:
            raise ValueError(f"{path} has no INPUTPILOT_RELEASE")
        text = text[:release_line.end()] + f"\nINPUTPILOT_CHANNEL = {channel}" + text[release_line.end():]
    path.write_text(text, encoding="utf-8")
    return value


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
    if RELEASE_PATTERN.search(updated):
        updated = RELEASE_PATTERN.sub(
            lambda match: f"{match.group(1)}$(INPUTPILOT_VERSION){match.group(3)}",
            updated,
        )
    if CHANNEL_PATTERN.search(updated):
        updated = CHANNEL_PATTERN.sub(
            lambda match: f"{match.group(1)}stable{match.group(3)}", updated
        )
    path.write_text(updated, encoding="utf-8")
    return new_version


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("show", "show-release", "set-release", "bump", "firmware-bcd"))
    parser.add_argument("part", nargs="?")
    parser.add_argument("--file", type=Path, default=DEFAULT_VERSION_FILE)
    args = parser.parse_args()
    if args.command == "bump":
        if args.part not in ("major", "minor", "patch"):
            parser.error("bump requires major, minor, or patch")
        print(bump_version(args.part, args.file))
    elif args.command == "set-release":
        if not args.part:
            parser.error("set-release requires MAJOR.MINOR.PATCH[-PRERELEASE]")
        print(set_release_version(args.part, args.file))
    elif args.command == "show-release":
        print(release_version(args.file))
    elif args.command == "firmware-bcd":
        print(firmware_bcd_literal(args.file))
    else:
        print(project_version(args.file))


if __name__ == "__main__":
    main()

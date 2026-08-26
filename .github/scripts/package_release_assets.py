#!/usr/bin/env python3
"""Validate CI artifacts and package versioned public release assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import struct
import zipfile
from pathlib import Path, PurePosixPath

LC_CODE_SIGNATURE = 0x1D
THIN_MAGICS = {
    b"\xce\xfa\xed\xfe": ("<", 28),  # MH_MAGIC
    b"\xfe\xed\xfa\xce": (">", 28),  # MH_CIGAM
    b"\xcf\xfa\xed\xfe": ("<", 32),  # MH_MAGIC_64
    b"\xfe\xed\xfa\xcf": (">", 32),  # MH_CIGAM_64
}
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}


def only_named_file(root: Path, name: str) -> Path:
    matches = [path for path in root.rglob(name) if path.is_file()]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {name!r} below {root}, found {matches}")
    if matches[0].stat().st_size == 0:
        raise ValueError(f"artifact is empty: {matches[0]}")
    return matches[0]


def thin_has_code_signature(data: bytes, base: int = 0) -> bool | None:
    magic = data[base : base + 4]
    if magic not in THIN_MAGICS:
        return None
    endian, header_size = THIN_MAGICS[magic]
    command_count = struct.unpack_from(endian + "I", data, base + 16)[0]
    command_bytes = struct.unpack_from(endian + "I", data, base + 20)[0]
    position = base + header_size
    limit = position + command_bytes
    if limit > len(data):
        raise ValueError("truncated Mach-O load commands")
    for _ in range(command_count):
        command, command_size = struct.unpack_from(endian + "II", data, position)
        if command_size < 8 or position + command_size > limit:
            raise ValueError("invalid Mach-O load command")
        if (command & 0x7FFFFFFF) == LC_CODE_SIGNATURE:
            return True
        position += command_size
    return False


def macho_has_code_signature(data: bytes) -> bool | None:
    direct = thin_has_code_signature(data)
    if direct is not None:
        return direct
    magic = data[:4]
    if magic not in FAT_MAGICS:
        return None
    endian, is_64_bit = FAT_MAGICS[magic]
    architecture_count = struct.unpack_from(endian + "I", data, 4)[0]
    position = 8
    results: list[bool] = []
    for _ in range(architecture_count):
        if is_64_bit:
            _, _, offset, _, _, _ = struct.unpack_from(endian + "IIQQII", data, position)
            position += 32
        else:
            _, _, offset, _, _ = struct.unpack_from(endian + "IIIII", data, position)
            position += 20
        result = thin_has_code_signature(data, offset)
        if result is None:
            raise ValueError("invalid fat Mach-O slice")
        results.append(result)
    return any(results)


def validate_apk(apk: Path) -> None:
    if not zipfile.is_zipfile(apk):
        raise ValueError(f"APK is not a ZIP archive: {apk}")
    with zipfile.ZipFile(apk) as archive:
        names = set(archive.namelist())
    required = {"AndroidManifest.xml", "classes.dex", "resources.arsc"}
    missing = sorted(required - names)
    if missing:
        raise ValueError(f"APK is missing required members: {missing}")


def validate_unsigned_ipa(ipa: Path) -> None:
    if not zipfile.is_zipfile(ipa):
        raise ValueError(f"IPA is not a ZIP archive: {ipa}")
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        app_roots = sorted(
            {
                "/".join(PurePosixPath(name).parts[:2]) + "/"
                for name in names
                if len(PurePosixPath(name).parts) >= 2
                and PurePosixPath(name).parts[0] == "Payload"
                and PurePosixPath(name).parts[1].endswith(".app")
            }
        )
        if app_roots != ["Payload/InputPilot.app/"]:
            raise ValueError(f"unexpected IPA app roots: {app_roots}")
        app_root = app_roots[0]
        forbidden = [
            name
            for name in names
            if "_CodeSignature" in PurePosixPath(name).parts
            or PurePosixPath(name).name == "embedded.mobileprovision"
            or PurePosixPath(name).suffix in {".mobileprovision", ".xcent"}
        ]
        if forbidden:
            raise ValueError(f"IPA contains signing material: {forbidden}")
        info = plistlib.loads(archive.read(app_root + "Info.plist"))
        bundle_id = info.get("CFBundleIdentifier")
        if bundle_id != "com.thorethy.inputpilot":
            raise ValueError(f"unexpected IPA bundle ID: {bundle_id!r}")
        executable = app_root + str(info["CFBundleExecutable"])
        if executable not in names:
            raise ValueError(f"IPA executable is missing: {executable}")
        macho_count = 0
        signed_machos: list[str] = []
        for name in names:
            if name.endswith("/"):
                continue
            status = macho_has_code_signature(archive.read(name))
            if status is not None:
                macho_count += 1
                if status:
                    signed_machos.append(name)
        if macho_count == 0:
            raise ValueError("IPA contains no Mach-O binary")
        if signed_machos:
            raise ValueError(f"IPA Mach-O binaries contain LC_CODE_SIGNATURE: {signed_machos}")


INITIAL_IMAGE_NAMES = ("bootloader.bin", "partitions.bin", "boot_app0.bin", "firmware.bin")
INITIAL_SUPPORT_NAMES = ("initial-flash-manifest.json", "flash_args")


def validate_initial_flash_assets(source: Path) -> dict:
    files = {name: only_named_file(source, name) for name in (*INITIAL_IMAGE_NAMES, *INITIAL_SUPPORT_NAMES, "initial-flash.bin")}
    manifest = json.loads(files["initial-flash-manifest.json"].read_text(encoding="utf-8"))
    if manifest.get("product") != "InputPilot" or manifest.get("board") != "esp32-s3-zero-4mb":
        raise ValueError("unexpected initial-flash manifest identity")
    entries = manifest.get("images")
    if not isinstance(entries, list) or [entry.get("file") for entry in entries] != list(INITIAL_IMAGE_NAMES):
        raise ValueError("initial-flash manifest has an unexpected image set or order")
    parsed = []
    for entry in entries:
        path = files[entry["file"]]
        try:
            offset = int(entry["offset"], 0)
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError("invalid initial-flash offset") from error
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if entry.get("size") != path.stat().st_size or entry.get("sha256") != digest:
            raise ValueError(f"initial-flash manifest does not match {path.name}")
        parsed.append((offset, path))
    if parsed != sorted(parsed) or len({offset for offset, _ in parsed}) != len(parsed):
        raise ValueError("initial-flash offsets must be unique and increasing")
    expected_args = " ".join(value for offset, path in parsed for value in (f"0x{offset:x}", path.name)) + "\n"
    if files["flash_args"].read_text(encoding="utf-8") != expected_args:
        raise ValueError("flash_args does not match initial-flash manifest")
    merged = files["initial-flash.bin"].read_bytes()
    for offset, path in parsed:
        data = path.read_bytes()
        if merged[offset:offset + len(data)] != data:
            raise ValueError(f"merged image does not contain the exact {path.name} bytes")
    if len(merged) > manifest.get("flashSize", 0):
        raise ValueError("merged image exceeds declared flash size")
    return manifest


def create_initial_flash_zip(source: Path, destination: Path) -> None:
    validate_initial_flash_assets(source)
    required_names = (*INITIAL_IMAGE_NAMES, *INITIAL_SUPPORT_NAMES, "README.txt")
    files = [only_named_file(source, name) for name in required_names]
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, arcname=path.name)
    with zipfile.ZipFile(destination) as archive:
        if sorted(archive.namelist()) != sorted(required_names):
            raise ValueError("initial-flash ZIP contains unexpected members")


def copy_ota_assets(source: Path, output: Path) -> list[Path]:
    copied = []
    for name in ("firmware.bin", "firmware.sha256", "firmware-manifest.json", *INITIAL_IMAGE_NAMES[:-1], "initial-flash-manifest.json"):
        destination = output / name
        shutil.copyfile(only_named_file(source, name), destination)
        copied.append(destination)
    manifest = json.loads((output / "firmware-manifest.json").read_text(encoding="utf-8"))
    firmware = output / "firmware.bin"
    digest = hashlib.sha256(firmware.read_bytes()).hexdigest()
    if manifest.get("size") != firmware.stat().st_size or manifest.get("sha256") != digest:
        raise ValueError("firmware manifest does not match firmware.bin")
    if (output / "firmware.sha256").read_text(encoding="utf-8") != f"{digest}  firmware.bin\n":
        raise ValueError("firmware.sha256 does not match firmware.bin")
    return copied


def write_checksums(output: Path, assets: list[Path]) -> Path:
    checksum_file = output / "SHA256SUMS.txt"
    lines = []
    for asset in sorted(assets, key=lambda path: path.name):
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()
        lines.append(f"{digest}  {asset.name}\n")
    checksum_file.write_text("".join(lines), encoding="utf-8")
    return checksum_file


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag):
        raise ValueError(f"release tag must match vMAJOR.MINOR.PATCH, got {args.tag!r}")

    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError(f"output directory must be empty: {args.output}")

    apk_source = only_named_file(args.input / "android", "app-debug.apk")
    ipa_source = only_named_file(args.input / "ios", "InputPilot-unsigned.ipa")
    validate_apk(apk_source)
    validate_unsigned_ipa(ipa_source)

    apk = args.output / f"InputPilot-{args.tag}-android.apk"
    ipa = args.output / f"InputPilot-{args.tag}-ios-unsigned.ipa"
    initial_zip = args.output / f"InputPilot-{args.tag}-initial-flash.zip"
    initial_bin = args.output / f"InputPilot-{args.tag}-initial-flash.bin"
    shutil.copyfile(apk_source, apk)
    shutil.copyfile(ipa_source, ipa)
    firmware_source = args.input / "firmware"
    validate_initial_flash_assets(firmware_source)
    version = args.tag.removeprefix("v")
    ota_manifest = json.loads(only_named_file(firmware_source, "firmware-manifest.json").read_text(encoding="utf-8"))
    initial_manifest = json.loads(only_named_file(firmware_source, "initial-flash-manifest.json").read_text(encoding="utf-8"))
    if ota_manifest.get("version") != version or initial_manifest.get("version") != version:
        raise ValueError("firmware manifests do not match the release tag")
    readme = firmware_source / "README.txt"
    readme.write_text(
        "This package is for initial USB installation or migration.\n"
        "Normal future updates must use only firmware.bin through the InputPilot app.\n"
        "Do not select bootloader.bin, partitions.bin or boot_app0.bin in the Firmware tab.\n",
        encoding="utf-8",
    )
    create_initial_flash_zip(firmware_source, initial_zip)
    shutil.copyfile(only_named_file(firmware_source, "initial-flash.bin"), initial_bin)
    ota_assets = copy_ota_assets(args.input / "firmware", args.output)
    checksum_file = write_checksums(args.output, [apk, initial_zip, initial_bin, ipa, *ota_assets])
    checksummed = {line.split("  ", 1)[1] for line in checksum_file.read_text(encoding="utf-8").splitlines()}
    published_without_checksum = {path.name for path in args.output.iterdir() if path != checksum_file}
    if checksummed != published_without_checksum:
        raise ValueError("SHA256SUMS.txt does not cover every other release asset")

    for path in (apk, initial_zip, initial_bin, ipa, *ota_assets, checksum_file):
        print(f"{path.name}\t{path.stat().st_size} bytes")


if __name__ == "__main__":
    main()

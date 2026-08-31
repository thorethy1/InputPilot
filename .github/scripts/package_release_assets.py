#!/usr/bin/env python3
"""Validate CI artifacts and package versioned public release assets."""

from __future__ import annotations

import argparse
import datetime as dt
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


def read_ipa_info(ipa: Path) -> dict:
    with zipfile.ZipFile(ipa) as archive:
        matches = [name for name in archive.namelist()
                   if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(matches) != 1:
            raise ValueError(f"expected one app Info.plist in {ipa}, found {matches}")
        return plistlib.loads(archive.read(matches[0]))


def create_altstore_source(ipa: Path, tag: str, release_date: str,
                           destination: Path) -> None:
    info = read_ipa_info(ipa)
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id != "com.thorethy.inputpilot" or version != tag.removeprefix("v") or not build:
        raise ValueError("IPA identity/version does not match the AltStore release")
    try:
        dt.date.fromisoformat(release_date)
    except ValueError as error:
        raise ValueError(f"invalid AltStore release date: {release_date}") from error
    asset_name = f"InputPilot-{tag}-ios-unsigned.ipa"
    base = "https://raw.githubusercontent.com/thorethy1/InputPilot/main"
    source = {
        "name": "InputPilot",
        "subtitle": "Secure local control for InputPilot hardware.",
        "description": "Install and update the InputPilot iOS companion app.",
        "website": "https://github.com/thorethy1/InputPilot",
        "iconURL": f"{base}/ios/InputPilot/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
        "tintColor": "#007AFF",
        "apps": [{
            "name": "InputPilot",
            "bundleIdentifier": bundle_id,
            "developerName": "MKF Labs",
            "subtitle": "Control InputPilot securely over Bluetooth or Wi-Fi.",
            "localizedDescription": "Securely pair, control, configure, diagnose, and update InputPilot ESP32-S3 devices.",
            "iconURL": f"{base}/ios/InputPilot/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
            "tintColor": "#007AFF",
            "category": "utilities",
            "screenshots": [
                f"{base}/docs/images/ios-device-list.jpg",
                f"{base}/docs/images/ios-device-detail.jpg",
            ],
            "versions": [{
                "version": version,
                "buildVersion": build,
                "date": release_date,
                "localizedDescription": f"InputPilot {version} release.",
                "downloadURL": f"https://github.com/thorethy1/InputPilot/releases/download/{tag}/{asset_name}",
                "size": ipa.stat().st_size,
                "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
                "minOSVersion": "17.0",
            }],
            "appPermissions": {
                "entitlements": [],
                "privacy": [
                    {"name": "BluetoothAlways", "usageDescription": info["NSBluetoothAlwaysUsageDescription"]},
                    {"name": "LocalNetwork", "usageDescription": info["NSLocalNetworkUsageDescription"]},
                ],
            },
        }],
        "news": [],
    }
    destination.write_text(json.dumps(source, indent=2) + "\n", encoding="utf-8")


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
    for name in ("firmware.bin", "firmware-manifest.json"):
        destination = output / name
        shutil.copyfile(only_named_file(source, name), destination)
        copied.append(destination)
    manifest = json.loads((output / "firmware-manifest.json").read_text(encoding="utf-8"))
    firmware = output / "firmware.bin"
    digest = hashlib.sha256(firmware.read_bytes()).hexdigest()
    if manifest.get("size") != firmware.stat().st_size or manifest.get("sha256") != digest:
        raise ValueError("firmware manifest does not match firmware.bin")
    return copied


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release-date", default=dt.datetime.now(dt.timezone.utc).date().isoformat())
    args = parser.parse_args()

    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag):
        raise ValueError(f"release tag must match vMAJOR.MINOR.PATCH, got {args.tag!r}")

    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError(f"output directory must be empty: {args.output}")

    ipa_source = only_named_file(args.input / "ios", "InputPilot-unsigned.ipa")
    validate_unsigned_ipa(ipa_source)

    ipa = args.output / f"InputPilot-{args.tag}-ios-unsigned.ipa"
    initial_zip = args.output / f"InputPilot-Firmware-{args.tag}.zip"
    initial_bin = args.output / "InitialFirmware.bin"
    shutil.copyfile(ipa_source, ipa)
    altstore_source = args.output / "altstore-source.json"
    create_altstore_source(ipa, args.tag, args.release_date, altstore_source)
    firmware_source = args.input / "firmware"
    validate_initial_flash_assets(firmware_source)
    version = args.tag.removeprefix("v")
    ota_manifest = json.loads(only_named_file(firmware_source, "firmware-manifest.json").read_text(encoding="utf-8"))
    initial_manifest = json.loads(only_named_file(firmware_source, "initial-flash-manifest.json").read_text(encoding="utf-8"))
    if ota_manifest.get("version") != version or initial_manifest.get("version") != version:
        raise ValueError("firmware manifests do not match the release tag")
    readme = firmware_source / "README.txt"
    readme.write_text(
        "INITIAL USB INSTALLATION / RECOVERY ONLY.\n"
        "Normal future updates must use the standalone firmware.bin release asset through the InputPilot app.\n"
        "The firmware.bin inside this ZIP is an internal component of the complete USB flash set.\n"
        "Do not select bootloader.bin, partitions.bin or boot_app0.bin in the Firmware tab.\n",
        encoding="utf-8",
    )
    create_initial_flash_zip(firmware_source, initial_zip)
    shutil.copyfile(only_named_file(firmware_source, "initial-flash.bin"), initial_bin)
    ota_assets = copy_ota_assets(args.input / "firmware", args.output)
    expected = {
        ipa.name, initial_zip.name, initial_bin.name,
        "firmware.bin", "firmware-manifest.json", altstore_source.name,
    }
    actual = {path.name for path in args.output.iterdir() if path.is_file()}
    if actual != expected:
        raise ValueError(f"unexpected public release asset set: {sorted(actual)}")

    for path in (initial_zip, initial_bin, ipa, altstore_source, *ota_assets):
        print(f"{path.name}\t{path.stat().st_size} bytes")


if __name__ == "__main__":
    main()

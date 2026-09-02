# InputPilot

[![CI](https://github.com/thorethy1/InputPilot/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/thorethy1/InputPilot/actions/workflows/ci.yml)
[![Firmware + unit tests](https://img.shields.io/github/actions/workflow/status/thorethy1/InputPilot/ci.yml?branch=main&job=Native%20unit%20tests%20%2B%20firmware%20build&label=firmware%20%2B%20unit%20tests)](https://github.com/thorethy1/InputPilot/actions/workflows/ci.yml)
[![iOS](https://img.shields.io/github/actions/workflow/status/thorethy1/InputPilot/ci.yml?branch=main&job=iOS%20build%20%2B%20unit%20tests&label=iOS)](https://github.com/thorethy1/InputPilot/actions/workflows/ci.yml)

**InputPilot** is ESP32-S3 firmware that appears to your computer as a USB mouse and keyboard, plus an iOS companion that controls it locally over BLE or persistent Wi-Fi/TCP. Setup establishes trust by USB, then uses the same authenticated Secure Protocol v2 over Bluetooth and Wi-Fi. Older firmware is intentionally unsupported and must be reflashed over USB.

No cloud relay, telemetry, computer-input capture, or Internet remote control is included. Use it only with computers you own or are authorized to control.

## Getting started

### 1. Hardware

Supported board: **Waveshare ESP32-S3-Zero / Mini** (ESP32-S3FH4R2, 4 MB flash,
WS2812).

<p align="center">
  <img src="https://docs.waveshare.com/assets/images/ESP32-S3-Zero-M-dc5172b1f2c465b7927cc20a567c6322.webp" alt="Waveshare ESP32-S3-Zero with USB-C connected" width="360">
</p>

- [Aliexpress listing](https://a.aliexpress.com/_ExnnLN0)
- [`usb-hid-s3/docs/HARDWARE.md`](usb-hid-s3/docs/HARDWARE.md)

2. Build & Flash

```bash
# Install dependencies
sudo apt update
sudo apt install python3 python3-pip python3-venv git
# (Optional) Create and activate a virtual environment
python3 -m venv ~/esptool-env
source ~/esptool-env/bin/activate
# Install esptool
pip install esptool
# Connect the ESP32-S3 via USB and identify its serial port
ls /dev/ttyACM* /dev/ttyUSB*
# Enter download mode:
# Hold BOOT, press and release RESET, then release BOOT
# Erase the existing flash contents
esptool --chip esp32s3 \
  --port /dev/ttyACM0 \
  erase-flash
# Flash the complete InputPilot image
# initial-flash.bin contains the bootloader, partition table,
# OTA boot data, and InputPilot firmware.
esptool --chip esp32s3 \
  --port /dev/ttyACM0 \
  --baud 460800 \
  write-flash 0x0 initial-flash.bin
# Disconnect and reconnect the USB cable.
```

Note: Replace /dev/ttyACM0 with the serial port assigned to your ESP32-S3 if necessary.

### 3. Companions

After flashing, sideload the InputPilot iOS companion app and securely pair it with the InputPilot device via USB.

- **[InputPilot for iOS](ios/)** — SwiftUI/SwiftData; secure setup, trackpad, keyboard, presets, macros, diagnostics and OTA. Secure Protocol v2 firmware is required.

<p align="center">
  <img src="docs/images/ios-device-list.jpg" alt="InputPilot device list showing two ready devices" width="240">
  &nbsp;
  <img src="docs/images/ios-device-detail.jpg" alt="InputPilot iOS firmware screen with device and update status" width="240">
</p>

### 4. Platform support

| Check | Where it runs |
|-------|----------------|
| Native unit tests (`pio test -e native`) | Linux / macOS / CI |
| Firmware compile (`pio run -e esp32s3`) | Linux / macOS / CI |
| iOS companion (`xcodebuild test`) | **macOS with Xcode 26+** / CI (`macos-26`) |

## AltStore

InputPilot can be installed and updated through AltStore-compatible sources. The source files live directly in this repository, while the unsigned IPA files remain versioned GitHub Release assets.

### Stable

Use the stable source for normal InputPilot releases:

```text
https://github.com/thorethy1/InputPilot/raw/main/app-repo.json
```

### Beta

Use the beta source to receive InputPilot prereleases:

```text
https://github.com/thorethy1/InputPilot/raw/main/app-repo-beta.json
```

Add the desired URL as a source in AltStore Classic or another compatible sideloading app. Stable releases update `app-repo.json`; prereleases update `app-repo-beta.json`. The source metadata points to the matching validated unsigned IPA in GitHub Releases.

## Layout

| Folder | Purpose |
|--------|---------|
| [`usb-hid-s3/`](usb-hid-s3/) | InputPilot firmware (USB HID + Secure Protocol v2 + discovery) |
| [`ios/`](ios/) | **InputPilot** iOS companion (SwiftUI) |

## CI

Badges above track the latest `main` workflow run
(`.github/workflows/ci.yml` on every PR and push to `main`):

- PlatformIO **native unit tests**
- **esp32s3 firmware compile**
- **InputPilot iOS** build + unit tests (`macos-26`, Xcode 26+ Simulator)

## Using the iOS remote

Flash firmware, then choose **Add Device → Set Up Securely**. The app establishes
trust through USB HID, authenticates the matching BLE identity, provisions Wi-Fi
inside that encrypted session, rediscovers the same device ID and verifies its
secure TCP session before saving it. There is no manual address or unencrypted
setup path. Bluetooth and Wi-Fi then provide the same controls;
the selected connection mode only changes transport preference.

- **Trackpad:** coalesced relative one-finger movement, two-finger scrolling, tap/double-tap click, long-press drag, mouse buttons, sensitivity and safety release.
- **Keyboard:** native event input (including Backspace, Enter, Tab and paste), navigation/editing keys, one-shot modifiers, shortcuts, and actual German QWERTZ or US QWERTY USB-HID mapping.
- **Presets:** local SwiftData text/shortcut items with favorite, duplicate, delete, reorder, optional Enter, and typing-delay metadata.
- **Macros:** records only actions produced inside this app, including timing. Playback supports 0.5×–2×, finite/infinite repeat and start delay. The visible STOP control cancels the queue and sends release-all.

Automatic transport selection uses BLE for small low-latency events, persistent TCP for longer text and event streams, and REST for management/fallback. Device settings also offer Prefer Bluetooth, Prefer Wi-Fi, Bluetooth Only, and Wi-Fi Only. The active transport is shown above the control tabs.

Wi-Fi and BLE may run together on the ESP32-S3. The firmware defaults to `wifi+ble`; the compatible serial command `radio wifi|ble|both|none` changes this at runtime. See [the protocol specification](docs/PROTOCOL.md) for GATT UUIDs, binary frames, TCP grammar, REST endpoints, capabilities, and authentication.

## Firmware installation

InputPilot ships one application firmware with two installation paths. `firmware.bin` is the same InputPilot application image included in the initial USB flash and used for later authenticated OTA updates. Initial installation additionally needs the bootloader, partition table, and OTA bootstrap image.

### First installation / required reflash

Use `InitialFirmware.bin` over USB, or flash the individual files from `InputPilot-Firmware-vX.Y.Z.zip` according to its manifest. This replaces the bootloader, partition table, OTA bootstrap data, and application. It also works after `esptool erase-flash`; no data from an older installation is assumed. See [the hardware guide](usb-hid-s3/docs/HARDWARE.md) for commands.

### Future firmware updates

Use the InputPilot iOS Firmware tab. The app downloads only `firmware-manifest.json` and `firmware.bin` from GitHub Releases, validates them, and transfers only `firmware.bin` over authenticated Wi-Fi or BLE OTA. Never select an initial-flash image, bootloader, partition table, or `boot_app0.bin` in the Firmware tab.

```text
New ESP32-S3
    │
    ▼
Initial USB flash ── bootloader + partitions + boot_app0 + firmware.bin
    │
    ▼
InputPilot installed
    │
    ▼
iOS app checks GitHub ── firmware-manifest.json + firmware.bin
    │
    ▼
Authenticated Wi-Fi or BLE OTA
```

## Firmware updates over Wi-Fi and Bluetooth

Firmware v0.8.7 uses OTA schema 1 on the 4 MB Waveshare ESP32-S3-Zero: NVS and OTA metadata, two 1,966,080-byte application slots, and coredump storage. PlatformIO checks every image against the real slot size. BLE OTA reuses the authenticated InputPilot NimBLE session; it transfers offset-framed chunks, uses ACK/window flow control, and verifies the complete SHA-256 digest before changing the boot partition. SHA-256 is an integrity check, not a cryptographic signature.

The Firmware tab can check GitHub Releases and validates product, board, protocol, OTA schema, size, and SHA-256 from `firmware-manifest.json`. For a manual `.bin`, the app validates the ESP32 image and embedded InputPilot product/board/version metadata; it never substitutes the installed version as the target. Foreign ESP32-S3 images, bootloaders, partition tables, invalid images, and oversized files are rejected before transfer. A cancellation, timeout, invalid offset, checksum failure, or Bluetooth disconnect aborts the pending slot and leaves the installed firmware active. After finalization, a disconnect is treated as the expected reboot; the app reconnects and verifies device identity, target version, and OTA schema before reporting success.

Devices flashed with an earlier partition table cannot update through the app. Perform the full USB reflash described above. It replaces the partition table, so Wi-Fi must be configured again.

Contributors should use `AppColors` and the `AccentColor` asset for the red brand accent. Success, warning, error, and informational states retain semantic system colors and always include text or symbols.

## iOS builds on GitHub

No local Mac is required for development handoff or signed builds. Regular GitHub Actions CI publishes ESP32-S3 firmware and an unsigned iOS device IPA on each `main` build. The unsigned IPA uses `com.thorethy.inputpilot` and contains no provisioning profile, registered-device UDIDs, Apple Team ID, or code signature. It must be signed with the installer's own Apple credentials before iOS will run it; self-signing tools may replace the bundle ID with an ID available to that Apple team.

Configure `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, and `KEYCHAIN_PASSWORD` as repository Actions secrets. `APPLE_TEAM_ID` and `IOS_BUNDLE_ID` are optional overrides and must match the supplied profile. Then use **Actions → iOS Signed Build → Run workflow**. The workflow replaces `InputPilot.ipa` in the unpublished **Private Signed InputPilot IPA** draft release and writes its direct download link to the run summary. Only authorized repository collaborators can access that draft; the signed IPA is never added to a public release.

Signing inputs are never committed or uploaded as artifacts and are reconstructed only under `$RUNNER_TEMP`. Detailed preparation, diagnostics, download and cleanup behavior are documented in [iOS CI/CD](docs/IOS_CICD.md).

## Versioned release assets

Use **Actions → Create release → Run workflow** and choose `patch`, `minor`, or
`major`. The worker updates the single version in `Version.xcconfig`, runs CI
with an automatically increasing iOS build number, creates the matching tag and
GitHub Release, and starts the verified asset workflow. App and firmware builds
both read this shared version; their project files do not contain release-number
copies.

| Asset | Content |
|-------|---------|
| `InputPilot-vX.Y.Z-ios-unsigned.ipa` | Unsigned iOS device IPA (for self-signing and AltStore-compatible sources) |
| `InitialFirmware.bin` | Single merged image for initial installation or required USB reflash; never OTA |
| `InputPilot-Firmware-vX.Y.Z.zip` | Individual initial-flash images, generated flash arguments, manifest, and instructions |
| `firmware.bin` | App-only image for normal authenticated Wi-Fi or BLE OTA |
| `firmware-manifest.json` | Permanent automatic-update contract containing version, compatibility, size, and SHA-256 |

The individual bootloader, partition, OTA bootstrap, checksum, and initial-flash manifest files remain inside the complete ZIP instead of being duplicated as public release assets. `firmware.bin` and `firmware-manifest.json` are always published together so older InputPilot apps can discover and verify future updates.

The repository-hosted AltStore-compatible feeds are documented in the [AltStore](#altstore) section above and are updated automatically when stable or beta releases are published.

CI artifacts (retained for 14 days) and release assets are independent — a release asset survives indefinitely. If the CI run for a tag commit is still in progress, the workflow waits for it (up to 15 minutes) and fails safely if no successful run was produced for that exact commit.

To repair a release whose assets were not attached (or to retry after a CI fix), run the workflow manually from **Actions → Attach release assets → Run workflow** with the published tag name. A manually created release remains supported when its tag matches `Version.xcconfig`.

## Development and tests

```bash
cd usb-hid-s3
pio test -e native
pio run -e esp32s3
```

iOS build/tests run with `xcodebuild test` in CI on `macos-26`; both workflows explicitly reject Xcode older than 26. Building against the iOS 26 SDK enables the system's native Liquid Glass appearance for the app's standard navigation, tab, toolbar, sheet, form, and button components; InputPilot does not simulate it on older SDKs. Firmware and iOS jobs run on pull requests and pushes to `main`.

The manual hardware and Liquid Glass release-candidate checklist is in [the hardware E2E test plan](docs/HARDWARE_E2E.md).

Current checked-in screenshots document the retained device list/detail flow. New Trackpad, Keyboard, Presets, and Macro Recorder screenshots must be captured from a real simulator/device after the macOS UI build; none are fabricated in this repository.

## Docs

- [`CHANGELOG.md`](CHANGELOG.md) — version history
- [`usb-hid-s3/docs/HARDWARE.md`](usb-hid-s3/docs/HARDWARE.md) — BOM & flash dance
- [`usb-hid-s3/docs/KNOWN_LIMITATIONS.md`](usb-hid-s3/docs/KNOWN_LIMITATIONS.md)
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — BLE, TCP and REST HID control protocol
- [`docs/UBUNTU_HARDWARE_TEST.md`](docs/UBUNTU_HARDWARE_TEST.md) — automated headless Ubuntu REST/TCP-to-USB proof
- [`docs/IOS_CICD.md`](docs/IOS_CICD.md) — signing and IPA builds without a local Mac

## Secrets

Do **not** commit:

- `usb-hid-s3/include/wifi_secrets.h`
- `usb-hid-s3/config.env`
- any app signing keys / `local.properties` / `.env` files

HID keyboard injection can look like malware to AV / IT policies. Use on systems
you own or have permission to automate.

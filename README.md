# InputPilot

[![CI](https://github.com/thorethy1/InputPilot/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/thorethy1/InputPilot/actions/workflows/ci.yml)
[![Firmware + unit tests](https://img.shields.io/github/actions/workflow/status/thorethy1/InputPilot/ci.yml?branch=main&job=Native%20unit%20tests%20%2B%20firmware%20build&label=firmware%20%2B%20unit%20tests)](https://github.com/thorethy1/InputPilot/actions/workflows/ci.yml)
[![OpenAPI](https://img.shields.io/github/actions/workflow/status/thorethy1/InputPilot/ci.yml?branch=main&job=OpenAPI%20lint&label=OpenAPI)](https://github.com/thorethy1/InputPilot/actions/workflows/ci.yml)
[![iOS](https://img.shields.io/github/actions/workflow/status/thorethy1/InputPilot/ci.yml?branch=main&job=iOS%20build%20%2B%20unit%20tests&label=iOS)](https://github.com/thorethy1/InputPilot/actions/workflows/ci.yml)
[![Android](https://img.shields.io/github/actions/workflow/status/thorethy1/InputPilot/ci.yml?branch=main&job=Android%20build%20%2B%20unit%20tests&label=Android)](https://github.com/thorethy1/InputPilot/actions/workflows/ci.yml)



**InputPilot 0.8.3** is ESP32-S3 firmware that appears to your computer as a USB mouse and keyboard, plus an iOS companion that controls it locally over BLE, persistent Wi-Fi/TCP, or REST. The app provides trustworthy live device/transport and firmware-update states, a scrolling trackpad, event-based live keyboard with real German QWERTZ and US QWERTY HID mapping, shortcuts, editable local presets, and recordable/playable macros.


No cloud relay, telemetry, computer-input capture, or Internet remote control is included. Use it only with computers you own or are authorized to control.

| Name | Where you see it |
|------|------------------|
| **InputPilot** | Product and GitHub repository |
| **usb-hid-s3** | Firmware folder / USB product family name |
| **hid-helper** | mDNS hostname prefix (`hid-helper-xxxx.local`; suffix from device MAC) |

## Getting started

### 1. Hardware

Supported board: **Waveshare ESP32-S3-Zero / Mini** (ESP32-S3FH4R2, 4 MB flash,
WS2812 on GPIO21).

<p align="center">
  <img src="https://docs.waveshare.com/assets/images/ESP32-S3-Zero-M-dc5172b1f2c465b7927cc20a567c6322.webp" alt="Waveshare ESP32-S3-Zero with USB-C connected" width="360">
</p>

- Buy example: [Aliexpress listing](https://a.aliexpress.com/_ExnnLN0)
- Details: [`usb-hid-s3/docs/HARDWARE.md`](usb-hid-s3/docs/HARDWARE.md)

### 2. Build & flash

```bash
cd usb-hid-s3
cp include/wifi_secrets.h.example include/wifi_secrets.h   # optional STA seed
cp config.env.example config.env                             # set ESP_PORT
# Enter download mode: hold BOOT, tap RESET, release BOOT
pio run -e esp32s3 -t upload
# Power-cycle the USB cable so the app enumerates as VID 0xCAFE
curl http://hid-helper-XXXX.local/api/status   # XXXX = device suffix from /api/status
```

Full commands, LED legend, and REST examples:
[`usb-hid-s3/README.md`](usb-hid-s3/README.md)  
OpenAPI: [`usb-hid-s3/docs/openapi.yaml`](usb-hid-s3/docs/openapi.yaml)

### 3. Companions (optional)

- **[InputPilot for iOS](ios/)** — SwiftUI/SwiftData; discovery, trackpad, keyboard, presets and macros. Firmware **0.5.0+** for all transports; older firmware is capability-detected.
- **[Android InputPilot](android/)** — Kotlin + Jetpack Compose; NSD, Soft-AP, same REST. Firmware **0.4.0+**. See [`android/README.md`](android/README.md).

<p align="center">
  <img src="docs/images/ios-device-list.jpg" alt="InputPilot device list showing two online hid-helpers" width="240">
  &nbsp;
  <img src="docs/images/ios-device-detail.jpg" alt="InputPilot iOS device detail with firmware version and jiggle toggle" width="240">
</p>

### 4. Platform support

| Check | Where it runs |
|-------|----------------|
| Native unit tests (`pio test -e native`) | Linux / macOS / CI |
| Firmware compile (`pio run -e esp32s3`) | Linux / macOS / CI |
| iOS companion (`xcodebuild test`) | **macOS with Xcode 26+** / CI (`macos-26`) |
| Android companion (`./gradlew test`) | Linux / macOS / CI (`ubuntu-latest`) |
| On-device pytest (serial / HID E2E / WiFi / BLE / mDNS) | **macOS + board** only |

## Layout

| Folder | Purpose |
|--------|---------|
| [`usb-hid-s3/`](usb-hid-s3/) | ESP32-S3 firmware (USB HID + WiFi REST + Soft-AP + mDNS) |
| [`ios/`](ios/) | **InputPilot** iOS companion (SwiftUI) |
| [`android/`](android/) | **InputPilot** Android companion (Kotlin + Compose) |

## CI

Badges above track the latest `main` workflow run
(`.github/workflows/ci.yml` on every PR and push to `main`):

- PlatformIO **native unit tests**
- **esp32s3 firmware compile**
- OpenAPI 3 schema validation and required-path audit
- **InputPilot iOS** build + unit tests (`macos-26`, Xcode 26+ Simulator)
- **InputPilot Android** unit tests + `assembleDebug` (`ubuntu-latest`)

## Using the iOS remote

Flash firmware, then choose **Add Device → Bluetooth → Scan Nearby** to onboard directly from the InputPilot manufacturer identity. The app reads device ID, name, firmware, protocol, OTA schema, capabilities, and authentication requirement over BLE and can save the device with no IP address or mDNS hostname. Bonjour, Soft-AP setup, and manual Wi-Fi addresses remain available. **Wi-Fi is optional; Bluetooth alone supports onboarding, control, status, and firmware updates.** The native tab bar keeps Devices, Control, Firmware, and Settings available without a custom bottom bar.

- **Trackpad:** coalesced relative one-finger movement, two-finger scrolling, tap/double-tap click, long-press drag, mouse buttons, sensitivity and safety release.
- **Keyboard:** native event input (including Backspace, Enter, Tab and paste), navigation/editing keys, one-shot modifiers, shortcuts, and actual German QWERTZ or US QWERTY USB-HID mapping.
- **Presets:** local SwiftData text/shortcut items with favorite, duplicate, delete, reorder, optional Enter, and typing-delay metadata.
- **Macros:** records only actions produced inside this app, including timing. Playback supports 0.5×–2×, finite/infinite repeat and start delay. The visible STOP control cancels the queue and sends release-all.

Automatic transport selection uses BLE for small low-latency events, persistent TCP for longer text and event streams, and REST for management/fallback. Device settings also offer Prefer Bluetooth, Prefer Wi-Fi, Bluetooth Only, and Wi-Fi Only. The active transport is shown above the control tabs.

Wi-Fi and BLE may run together on the ESP32-S3. The firmware defaults to `wifi+ble`; the compatible serial command `radio wifi|ble|both|none` changes this at runtime. See [the protocol specification](docs/PROTOCOL.md) for GATT UUIDs, binary frames, TCP grammar, REST endpoints, capabilities, and authentication.

## Firmware installation

InputPilot ships one application firmware with two installation paths. `firmware.bin` is the same InputPilot application image included in the initial USB flash and used for later BLE OTA updates. Initial installation additionally needs the bootloader, partition table, and OTA bootstrap image.

### First installation / migration

Use `InputPilot-vX.Y.Z-initial-flash.bin` over USB, or flash the individual files from `InputPilot-vX.Y.Z-initial-flash.zip` according to its manifest. This replaces the bootloader, partition table, OTA bootstrap data, and application. It also works after `esptool erase-flash`; no data from an older installation is assumed. See [the hardware guide](usb-hid-s3/docs/HARDWARE.md) for commands.

### Future firmware updates

Use the InputPilot iOS Firmware tab. The app downloads only `firmware-manifest.json` and `firmware.bin` from GitHub Releases, validates them, and transfers only `firmware.bin` through BLE OTA. Never select an initial-flash image, bootloader, partition table, or `boot_app0.bin` in the Firmware tab.

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
BLE OTA
```

## Bluetooth firmware updates

Firmware v0.8.3 uses OTA schema 1 on the 4 MB Waveshare ESP32-S3-Zero: NVS and OTA metadata, two 1,966,080-byte application slots, and coredump storage. PlatformIO checks every image against the real slot size. BLE OTA reuses the authenticated InputPilot NimBLE session; it transfers offset-framed chunks, uses ACK/window flow control, and verifies the complete SHA-256 digest before changing the boot partition. SHA-256 is an integrity check, not a cryptographic signature.

The Firmware tab can check GitHub Releases and validates product, board, protocol, OTA schema, size, and SHA-256 from `firmware-manifest.json`. For a manual `.bin`, the app validates the ESP32 image and embedded InputPilot product/board/version metadata; it never substitutes the installed version as the target. Foreign ESP32-S3 images, bootloaders, partition tables, invalid images, and oversized files are rejected before transfer. A cancellation, timeout, invalid offset, checksum failure, or Bluetooth disconnect aborts the pending slot and leaves the installed firmware active. After finalization, a disconnect is treated as the expected reboot; the app reconnects and verifies device identity, target version, and OTA schema before reporting success.

Devices flashed with the earlier factory-only partition table cannot migrate through a normal app OTA. Perform the one-time USB migration described above. This full USB flash replaces the partition table, so back up/re-enter Wi-Fi credentials if needed.

Contributors should use `AppColors` and the `AccentColor` asset for the red brand accent. Success, warning, error, and informational states retain semantic system colors and always include text or symbols.

## iOS builds on GitHub

No local Mac is required for development handoff or signed builds. Regular GitHub Actions CI publishes three downloadable artifacts on each `main` build: ESP32-S3 firmware, the Android debug APK, and an unsigned iOS device IPA. The unsigned IPA uses `com.thorethy.inputpilot` and contains no provisioning profile, registered-device UDIDs, Apple Team ID, or code signature. It must be signed with the installer's own Apple credentials before iOS will run it; self-signing tools may replace the bundle ID with an ID available to that Apple team.

Configure `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, and `KEYCHAIN_PASSWORD` as repository Actions secrets. `APPLE_TEAM_ID` and `IOS_BUNDLE_ID` are optional overrides and must match the supplied profile. Then use **Actions → iOS Signed Build → Run workflow** and download `InputPilot.ipa` from that run's artifacts. Personal development/ad-hoc IPAs are never uploaded to a public GitHub Release by the workflow.

Signing inputs are never committed or uploaded as artifacts and are reconstructed only under `$RUNNER_TEMP`. Detailed preparation, diagnostics, download and cleanup behavior are documented in [iOS CI/CD](docs/IOS_CICD.md).

## Versioned release assets

Creating a [GitHub Release](https://github.com/thorethy1/InputPilot/releases) with a `vMAJOR.MINOR.PATCH` tag validates all project versions and attaches application and firmware assets:

| Asset | Content |
|-------|---------|
| `InputPilot-vX.Y.Z-android.apk` | Android debug APK |
| `InputPilot-vX.Y.Z-ios-unsigned.ipa` | Unsigned iOS device IPA (for self-signing) |
| `InputPilot-vX.Y.Z-initial-flash.bin` | Single merged image for initial USB installation or migration; never OTA |
| `InputPilot-vX.Y.Z-initial-flash.zip` | Individual initial-flash images, generated flash arguments, manifest, and instructions |
| `firmware.bin` | App-only image for normal BLE OTA |
| `firmware.sha256` / `firmware-manifest.json` | Automatically generated OTA integrity and compatibility metadata |
| `bootloader.bin` / `partitions.bin` / `boot_app0.bin` | Individual initial USB flash assets; never OTA images |
| `initial-flash-manifest.json` | Build-derived offsets, sizes, and SHA-256 hashes for the full flash set |
| `SHA256SUMS.txt` | Checksum file for every published asset |

CI artifacts (retained for 14 days) and release assets are independent — a release asset survives indefinitely. If the CI run for a tag commit is still in progress, the workflow waits for it (up to 15 minutes) and fails safely if no successful run was produced for that exact commit.

To repair a release whose assets were not attached (or to retry after a CI fix), run the workflow manually from **Actions → Attach release assets → Run workflow** with the published tag name.

## Development and tests

```bash
cd usb-hid-s3
pio test -e native
pio run -e esp32s3

cd ../android
./gradlew :app:testDebugUnitTest :app:assembleDebug --no-daemon
```

iOS build/tests run with `xcodebuild test` in CI on `macos-26`; both workflows explicitly reject Xcode older than 26. Building against the iOS 26 SDK enables the system's native Liquid Glass appearance for the app's standard navigation, tab, toolbar, sheet, form, and button components; InputPilot does not simulate it on older SDKs. OpenAPI validation and all three platform jobs run on pull requests and pushes to `main`.

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

# HID Remote / inputpilot

[![CI](https://github.com/thorethy1/inputpilot/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/thorethy1/inputpilot/actions/workflows/ci.yml)
[![Firmware + unit tests](https://img.shields.io/github/actions/workflow/status/thorethy1/inputpilot/ci.yml?branch=main&job=Native%20unit%20tests%20%2B%20firmware%20build&label=firmware%20%2B%20unit%20tests)](https://github.com/thorethy1/inputpilot/actions/workflows/ci.yml)
[![OpenAPI](https://img.shields.io/github/actions/workflow/status/thorethy1/inputpilot/ci.yml?branch=main&job=OpenAPI%20lint&label=OpenAPI)](https://github.com/thorethy1/inputpilot/actions/workflows/ci.yml)
[![iOS](https://img.shields.io/github/actions/workflow/status/thorethy1/inputpilot/ci.yml?branch=main&job=iOS%20build%20%2B%20unit%20tests&label=iOS)](https://github.com/thorethy1/inputpilot/actions/workflows/ci.yml)
[![Android](https://img.shields.io/github/actions/workflow/status/thorethy1/inputpilot/ci.yml?branch=main&job=Android%20build%20%2B%20unit%20tests&label=Android)](https://github.com/thorethy1/inputpilot/actions/workflows/ci.yml)

**HID Remote** is an ESP32-S3 firmware that appears to your computer as a USB mouse and keyboard, plus an iOS companion that controls it locally over BLE, persistent Wi-Fi/TCP, or REST. The app provides a trackpad, live keyboard, shortcuts, local presets, and recordable/playable macros.


No cloud relay, telemetry, computer-input capture, or Internet remote control is included. Use it only with computers you own or are authorized to control.

| Name | Where you see it |
|------|------------------|
| **inputpilot** | GitHub repository |
| **usb-hid-s3** | Firmware folder / USB product family name |
| **hid-helper** | mDNS hostname prefix (`hid-helper-xxxx.local`; suffix from device MAC) |

## Getting started

### 1. Hardware

Supported board: **Waveshare ESP32-S3-Zero / Mini** (ESP32-S3FH4R2, 4 MB flash,
WS2812 on GPIO21).

<p align="center">
  <img src="docs/images/esp32-s3-zero.jpg" alt="Waveshare ESP32-S3-Zero with USB-C connected" width="360">
</p>

- Buy example: [Amazon listing](https://a.co/d/0fwrWUFU)
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

- **[iOS HID Remote](ios/)** — SwiftUI/SwiftData; discovery, trackpad, keyboard, presets and macros. Firmware **0.5.0+** for all transports; older firmware is capability-detected.
- **[Android InputPilot](android/)** — Kotlin + Jetpack Compose; NSD, Soft-AP, same REST. Firmware **0.4.0+**. See [`android/README.md`](android/README.md).

<p align="center">
  <img src="docs/images/ios-device-list.jpg" alt="iOS InputPilot device list showing two online hid-helpers" width="240">
  &nbsp;
  <img src="docs/images/ios-device-detail.jpg" alt="iOS device detail for Mover 1 with firmware 0.4.0 and jiggle toggle" width="240">
</p>

### 4. Platform support

| Check | Where it runs |
|-------|----------------|
| Native unit tests (`pio test -e native`) | Linux / macOS / CI |
| Firmware compile (`pio run -e esp32s3`) | Linux / macOS / CI |
| iOS companion (`xcodebuild test`) | **macOS** / CI (`macos-15`) |
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
- OpenAPI YAML sanity check
- **InputPilot iOS** build + unit tests (`macos-15` Simulator)
- **InputPilot Android** unit tests + `assembleDebug` (`ubuntu-latest`)

## Using the iOS remote

Flash firmware, provision the ESP32-S3 onto the same local network, then add it in the app through Bonjour, Soft-AP setup, or its address. Open the saved device and choose **Open Trackpad & Keyboard**.

- **Trackpad:** relative one-finger movement, tap/double-tap click, long-press drag, mouse buttons, sensitivity and haptics.
- **Keyboard:** immediate text, navigation/editing keys, common modifier combinations, German QWERTZ or US QWERTY selection.
- **Presets:** local SwiftData text/shortcut items with favorite, duplicate, delete, reorder, optional Enter, and typing-delay metadata.
- **Macros:** records only actions produced inside this app, including timing. Playback supports 0.5×–2×, finite/infinite repeat and start delay. The visible STOP control cancels the queue and sends release-all.

Automatic transport selection uses BLE for small low-latency events, persistent TCP for longer text and event streams, and REST for management/fallback. Device settings also offer Prefer Bluetooth, Prefer Wi-Fi, Bluetooth Only, and Wi-Fi Only. The active transport is shown above the control tabs.

Wi-Fi and BLE may run together on the ESP32-S3. The firmware defaults to `wifi+ble`; the compatible serial command `radio wifi|ble|both|none` changes this at runtime. See [the protocol specification](docs/PROTOCOL.md) for GATT UUIDs, binary frames, TCP grammar, REST endpoints, capabilities, and authentication.

## iOS builds on GitHub

No local Mac is required for development handoff or signed builds. GitHub Actions uses a hosted macOS runner for unsigned builds/tests and a manually triggered workflow for manual Apple signing.

Configure `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, and `KEYCHAIN_PASSWORD` as repository Actions secrets. `APPLE_TEAM_ID` and `IOS_BUNDLE_ID` are optional overrides and must match the supplied profile. Then use **Actions → iOS Signed Build → Run workflow** and download `HIDRemote.ipa` from the run artifacts. A `v*` tag can also attach the IPA to a GitHub Release.

Signing inputs are never committed or uploaded as artifacts and are reconstructed only under `$RUNNER_TEMP`. Detailed preparation, diagnostics, download and cleanup behavior are documented in [iOS CI/CD](docs/IOS_CICD.md).

## Development and tests

```bash
cd usb-hid-s3
pio test -e native
pio run -e esp32s3

cd ../android
./gradlew :app:testDebugUnitTest :app:assembleDebug --no-daemon
```

iOS build/tests run with `xcodebuild test` in CI on `macos-15`. OpenAPI validation and all three platform jobs run on pull requests and pushes to `main`. Hardware E2E suites require a connected ESP32-S3 and are documented under `usb-hid-s3/tests`.

Current checked-in screenshots document the retained device list/detail flow. New Trackpad, Keyboard, Presets, and Macro Recorder screenshots must be captured from a real simulator/device after the macOS UI build; none are fabricated in this repository.

## Docs

- [`CHANGELOG.md`](CHANGELOG.md) — version history
- [`usb-hid-s3/docs/HARDWARE.md`](usb-hid-s3/docs/HARDWARE.md) — BOM & flash dance
- [`usb-hid-s3/docs/KNOWN_LIMITATIONS.md`](usb-hid-s3/docs/KNOWN_LIMITATIONS.md)
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — BLE, TCP and REST HID control protocol
- [`docs/IOS_CICD.md`](docs/IOS_CICD.md) — signing and IPA builds without a local Mac
## Secrets

Do **not** commit:

- `usb-hid-s3/include/wifi_secrets.h`
- `usb-hid-s3/config.env`
- any app signing keys / `local.properties` / `.env` files

HID keyboard injection can look like malware to AV / IT policies. Use on systems
you own or have permission to automate.

# Changelog

## [0.5.0] - 2026-08-25

- Added first-class BLE binary control with versioned Control, Mouse, Keyboard, and Status characteristics.
- Added simultaneous Wi-Fi and BLE operation, persistent TCP control, capabilities, button state, and central release-all safety.
- Added the iOS adaptive connection manager, remote trackpad, live keyboard, QWERTZ/QWERTY selection, SwiftData presets, macro recording, timed playback, and emergency STOP.
- Added reproducible GitHub-hosted macOS signing/export and tagged-release IPA publishing.
- Preserved Android, REST, TCP line commands, Nordic UART compatibility, provisioning, and all existing discovery flows.

All notable changes to **inputpilot** / `usb-hid-s3` are documented here.
Firmware version is `FW_VERSION` in `usb-hid-s3/include/Config.h`.

## 0.4.0

- Per-device identity from WiFi MAC: Soft-AP `usb-hid-s3-XXXX`, mDNS
  `hid-helper-xxxx.local` (suffix = last 4 hex of MAC)
- `GET /api/status` and `GET /api/wifi` include `device_id` (12 lowercase hex)
- mDNS HTTP service TXT records: `path`, `id`, `fw`
- OpenAPI, README, and E2E tests updated for per-device discovery

## 0.3.4

- OpenAPI spec and docs aligned with optional `CONTROL_API_TOKEN` auth

## 0.3.3

- USB HID mouse + keyboard (ESP32 core native USB-OTG)
- USB-CDC serial command interface
- WiFi XOR BLE radio control (NUS / TCP `:3333` / HTTP `:80`)
- Soft-AP WiFi provisioning portal (`usb-hid-s3-setup`)
- mDNS hostname `hid-helper.local`
- WS2812 status LED (GPIO21, RGB order)
- OpenAPI 3 spec at `usb-hid-s3/docs/openapi.yaml`
- Cloud CI: native unit tests + firmware compile + OpenAPI check

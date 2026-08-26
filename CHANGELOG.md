# Changelog

## [0.8.0] - 2026-08-26

### Added

- Authenticated, versioned BLE firmware updates with offset/ACK flow control, cancellation, timeouts, reconnect handling, and mandatory SHA-256 integrity verification.
- Native iOS Devices, Control, Firmware, and Settings tab navigation, a manual `.bin` firmware picker, and BLE-only device/update UX.
- Explicit Bluetooth transport visibility and centralized red native accent/theme tokens.

### Changed

- Replaced the factory-only 4 MB partition layout with OTA schema 1: two 1,966,080-byte app slots plus NVS, OTA metadata, and coredump partitions.
- Expanded status capabilities with `ble_ota` and `ota_schema` while retaining existing REST, TCP, NUS, HID, identity, credentials, and authentication contracts.
- Release builds now produce `firmware.bin`, `firmware.sha256`, `firmware-manifest.json`, `bootloader.bin`, and `partitions.bin` with automatic size/hash metadata.

### Security

- BLE OTA requires the existing per-session control authentication, never activates incomplete or hash-mismatched images, and aborts safely on disconnect or timeout.
- SHA-256 verifies firmware integrity; it is not described as a cryptographic firmware signature.

## [0.6.4] - 2026-08-26

- Simplified app icon to a clean paper-plane-only design. Removed the ESP32 antenna, wireless arcs, mouse and keyboard symbols. Just the plane.

## [0.6.3] - 2026-08-26

- New app icon: flat bold-red paper plane with faceted shading, ESP32 PCB antenna, wireless transmission paths to mouse and keyboard. Transparent background for iOS Liquid Glass.
- Removed dark tile background from icon — iOS applies its own backdrop.

## [0.6.2] - 2026-08-26

- New app icon: dark Liquid-Glass tile with red ESP32 PCB antenna, wireless arcs, paper plane, and mouse+keyboard input symbols. Designed for iOS 26+ Liquid Glass appearance.
- Rebranded all user-visible "HID helper" and "InputPilot" terminology to "InputPilot" throughout the iOS companion, Android companion, and USB product identity.
- USB product name changed from "S3 Mouse+Keyboard" to "InputPilot S3".
- Updated Android adaptive icon with matching paper-plane symbol.
- Firmware version bumped to v0.6.2.

## [0.6.1] - 2026-08-26

- Confirmed BLE and TCP token authentication with explicit firmware replies, receive loops, failure states, and bounded timeouts before transports become ready.
- Kept drag, keyboard text, presets, and macro playback on ordered transport sessions; transport loss now aborts safely and attempts release-all before later work can fail over.
- Improved capability-aware controls and unsupported-protocol messaging while retaining progressive support for older firmware.
- Corrected radio-mode, companion-app, upstream attribution, and security documentation.
- Added focused auth/ordering regressions and an honest hardware validation record; physical and signed-device checks remain explicitly manual where hardware or signing secrets are required.

## [0.6.0] - 2026-08-26

- Added native live-keyboard event capture and real German QWERTZ/US QWERTY USB-HID mapping, including AltGr and umlauts, through the backward-compatible report event.
- Added two-finger scrolling, mouse-event coalescing, drag/release safety, editable presets with typing delay, and safer macro recording/playback management.
- Added stable BLE device identity matching and persisted firmware protocol/capability metadata.
- Moved iOS CI and signing to Xcode 26+ for native Liquid Glass and made personal signed IPAs manual Actions artifacts only, never automatic public release assets.
- Extended firmware capabilities, protocol/OpenAPI documentation, native/iOS tests, and the hardware E2E plan.
- Persisted capability metadata on initial device save, rejected unsupported future protocol versions, and exposed explicit connecting/reconnecting/authentication transport states.
- Completed all preset creation fields and upgraded CI from YAML parsing to OpenAPI schema validation.

## [0.5.0] - 2026-08-25

- Added first-class BLE binary control with versioned Control, Mouse, Keyboard, and Status characteristics.
- Added simultaneous Wi-Fi and BLE operation, persistent TCP control, capabilities, button state, and central release-all safety.
- Added the iOS adaptive connection manager, remote trackpad, live keyboard, QWERTZ/QWERTY selection, SwiftData presets, macro recording, timed playback, and emergency STOP.
- Added reproducible GitHub-hosted macOS signing/export and tagged-release IPA publishing.
- Preserved Android, REST, TCP line commands, Nordic UART compatibility, provisioning, and all existing discovery flows.

All notable changes to **InputPilot** / `usb-hid-s3` are documented here.
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

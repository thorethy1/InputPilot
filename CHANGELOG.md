# Changelog

## [0.8.9] - 2026-08-28

### Fixed

- Restore BLE OTA reliability and post-restart verification for securely paired devices.
- Restore USB defaults through the encrypted Bluetooth management channel after secure migration, while retaining the MAC-derived USB serial number.
- Advertise `secure_usb_identity_v1` so older paired firmware is never mistaken for supporting the encrypted reset command.
- Advertise and report the per-device `InputPilot-XXXX` name over Bluetooth and the HTTP API.
- Coalesce high-frequency scroll traffic to prevent encrypted-control queue growth and app instability.
- Make Preset Run an independent button instead of activating the typing-speed picker.
- Show only the selected control transport status at the top of the control screen.
- Use a long press for right click and tap-then-hold for left-button drag and drop.

## [0.8.8] - 2026-08-28

### Security

- Make USB pairing the default first step for new-device setup and restrict the following BLE scan to the paired device ID.
- Provision Wi-Fi credentials through a compact authenticated AES-GCM BLE management frame, including maximum-length SSIDs and passwords containing spaces, without using the plaintext setup portal.
- Route paired Keep Awake settings and test actions through encrypted BLE or Wi-Fi/TCP; REST remains available only for unpaired legacy migration.
- Add prominent unencrypted-communication warnings, per-device security state, and an in-app migration/recovery guide.

### Compatibility

- Preserve BLE and Wi-Fi for paired devices while retaining BLE, TCP, REST, API-token, and Soft-AP discovery paths for unpaired older firmware.
- Advertise `secure_wifi_setup_v1` so the app only offers encrypted credential provisioning to firmware that implements it.

### Repository

- Move the Android companion into a private archived repository and remove it from the active source tree and release documentation.
- Refresh the iOS screenshots and remove obsolete predecessor-product references from current documentation.

## [0.8.7] - 2026-08-28

### Security

- Turn the successful USB input proof into pairing: BOOT generates and persists a fresh 128-bit device credential, and iOS validates the frame and stores it as a this-device-only Keychain item.
- Add an HMAC-SHA-256 authenticated handshake, HKDF-SHA-256 session keys, and AES-256-GCM encrypted BLE and Wi-Fi/TCP control records with directional nonces and replay counters.
- Require BLE Secure Connections encryption for control characteristics and reject plaintext REST control, settings, credentials, diagnostics, and OTA after pairing. Minimal discovery metadata remains public.
- Keep the legacy compile-time API token only for unpaired upgrade compatibility; secure pairing does not require a secret compiled into firmware.

### Release

- Remove archived Android artifacts and Android version checks from public release packaging.
- Repair v0.8.6's missing public firmware and unsigned-iOS assets.

## [0.8.6] - 2026-08-28

### Added

- Added independent, persistent firmware schedules for periodic pointer movement and left click, with separate iOS toggles, interval pickers, and test actions over BLE or Wi-Fi.
- Added the first non-enforcing secure-onboarding hardware proof: holding BOOT after USB startup types a single-use 128-bit pairing test frame that the iOS Settings screen can validate without logging or retaining the credential.
- Documented the staged USB-authenticated key exchange and encrypted BLE/Wi-Fi transport design, including explicit hardware gates before enforcement.

### Changed

- Bluetooth presence now reads “Ready” and Wi-Fi presence reads “Online,” with the transport explained in the supporting description.
- Keep Awake runs in firmware after the phone disconnects and restores its movement/click configuration from NVS after restart.
- v0.8.6 development focuses on firmware and iOS; Android remains unchanged pending a separate archival task.

## [0.8.5] - 2026-08-28

### Fixed
- Updated the two stale iOS jiggle-routing tests to match direct-IP-first endpoint selection, fixing the v0.8.4 CI failure.
- Preboots one exact iOS simulator without parallel test clones and builds the unsigned device IPA in a parallel CI job.

### Added
- Added authenticated `/api/usb` read/update/reset operations backed by NVS, with editable USB product name, VID, PID, and serial number in the iOS device screen.
- USB defaults are now product `InputPilot`, VID/PID `CAFE:4001`, and a stable serial derived from the ESP32-S3 chip MAC.
- The private signed-iOS workflow now places a directly downloadable `InputPilot.ipa` in an unpublished draft release.

### Changed
- Firmware runtime identity is `InputPilot-Firmware`, Soft-AP names are `InputPilot-XXXX`, and Bonjour names are `inputpilot-xxxx.local`; iOS and Android retain legacy discovery compatibility.
- Public releases keep the full initial-flash ZIP, `InitialFirmware.bin`, `firmware.bin`, the permanent `firmware-manifest.json`, Android APK, and unsigned iOS IPA without duplicating internal flash components.

## [0.8.4] - 2026-08-28

### Fixed

- Wi-Fi control, status, diagnostics, and firmware updates now prefer a saved direct address and use Bonjour only as a discovery/fallback mechanism.
- Manual IP or VPN-host connections retain the address that actually answered instead of replacing it with the device-reported LAN address.
- Wi-Fi firmware updates preflight the available direct endpoints and verify the restarted device across the same candidate set.

### Added

- iOS and Android regressions for direct-address precedence and VPN-address persistence.

## [0.8.3] - 2026-08-28

### Fixed

- Replaced capability-derived Bluetooth availability with live radio, discovery, connection, authentication, and ready states shared across Devices, Control, Firmware, and Settings.
- Saved devices on iOS and Android now start in a checking state, clearly become offline when unavailable, and no longer retain misleading ready/active presentation after transport loss.
- Fixed unhandled Bluetooth connection failures, duplicate per-token sessions, stale reconnect presentation, session cleanup on device deletion, and false OTA failures caused by ordinary Bluetooth disconnects while no update was active.
- Firmware management now distinguishes installed and latest versions, update availability, up-to-date/newer installs, incompatible firmware, app-version requirements, and release-check failures.

### Changed

- Removed the pointer-jiggle switch from iOS and Android device rows and reworked it as the explanatory “Keep Awake” setting in device management, available only over live Wi-Fi.
- Replaced “Ready to Move,” “Moving,” and generic OTA “Available” labels with transport and firmware states that describe what the user can actually do.

### Added

- Focused regressions for initial/offline/reconnected presence, transport precedence, firmware compatibility, up-to-date firmware, and newer-app requirements.

## [0.8.2] - 2026-08-27

### Fixed

- Serialized acknowledged CoreBluetooth HID writes, used flow-controlled unacknowledged writes for coalesced movement/scroll, and reduced trackpad transport rate to 50 Hz.
- Moved BLE binary decode/KeyMap/logging work from the NimBLE host callback into the Arduino loop and reused the per-device BLE session for diagnostics.
- Unified mouse and keyboard reports on one checked Arduino-ESP32 USBHID sender with pinned report-ID/size assertions and real USB success/failure counters.

### Added

- RTC-resident HID crash breadcrumbs, expanded transport-neutral diagnostics, and a flash core-dump decoding helper.
- A bottom-up v0.8.2 hardware test gate; all physical results are initially NOT RUN.

## [0.8.1] - 2026-08-27

### Fixed

- USB mouse and keyboard reports now execute in the bounded Arduino main-loop executor instead of a dedicated FreeRTOS task.
- Mouse button transitions emit actual USB reports, BLE HID writes prefer acknowledged writes, and stateful events are not blindly retried after uncertain delivery.
- Added end-to-end HID counters, BLE disconnect context, bounded app logs, backwards-compatible firmware log decoding, and build commit diagnostics.

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
- Rebranded all legacy product terminology to "InputPilot" throughout the iOS companion, Android companion, and USB product identity.
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

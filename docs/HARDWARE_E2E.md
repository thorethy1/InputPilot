# InputPilot hardware E2E test plan

## v0.8.0 BLE OTA release gate (Waveshare ESP32-S3-Zero, 4 MB)

This gate cannot be replaced by simulator or host tests. Record board revision, iPhone/iOS version, source/target firmware versions, and observed USB HID result.

1. Flash `bootloader.bin`, `partitions.bin`, and `firmware.bin` over USB to establish OTA schema 1.
2. Connect the iPhone over BLE, complete token authentication when configured, and start an update from the native Firmware tab.
3. Confirm 100% transfer, SHA-256 verification, reboot, automatic reconnect, expected new version, and working USB mouse/keyboard/release-all.
4. Repeat with a token failure, invalid image, oversized declaration, wrong SHA-256, and explicit Cancel; no failed case may select the pending partition.
5. Start another update and disconnect Bluetooth near 50%. Power-cycle the ESP32, verify that the prior firmware and USB HID still work, then complete a fresh OTA successfully.
6. Exercise BLE-only, Wi-Fi-only, and combined Automatic control plus small/large iPhone layouts, portrait/landscape where supported, Light/Dark Mode, Dynamic Type, VoiceOver, Reduce Motion, and Increased Contrast.

Attach the completed observation record to the v0.8.0 release. If physical hardware or a signed iOS build is unavailable, mark this gate **not run**; do not infer success from compilation.

Record the firmware/app commit, board device ID, host OS/layout, iPhone/iOS version, Xcode version, transport, and pass/fail evidence for every run. Use firmware 0.6.1 and an app built with Xcode 26 or newer. Release results belong in `HARDWARE_E2E_RESULTS_0.6.1.md`.

## USB HID and transports

- Mouse: move in every direction; left/right/middle click; vertical scroll; long-press drag and release.
- German host layout: verify `y z ä ö ü ß @ € ? ! / \` plus upper-case umlauts and the documented symbol set.
- US host layout: verify lower/upper-case letters, digits, shifted and unshifted symbols.
- Repeat the controls over BLE, TCP, and forced REST fallback; then with Wi-Fi and BLE enabled together.
- Save two boards as different devices and verify each screen connects only to its matching BLE identity.
- Reboot the ESP32 during TCP use and verify reconnect/fallback. Disable/re-enable Bluetooth and Wi-Fi and verify bounded reconnect and correct status.

## Presets and macros

- Create, edit, favorite, duplicate, reorder, run, and delete text and shortcut presets.
- Verify Fast/10/25/50/100 ms typing, a multiline preset, a long preset, optional Enter, and cancellation on disconnect.
- Record mouse, keyboard, and a preset; save with name/description; rename, duplicate, play with timing/repeat, and delete.
- Press STOP during playback and verify no later event is sent and all mouse buttons/modifiers are released.

## Safety

- Disconnect each transport during drag; background the app while dragging and while a modifier is active.
- Background the app during macro playback and trigger a transport/auth failure during playback.
- In every case verify `mouseUp`/`release all`, immediate UI stop, and no unattended continuation.

## Liquid Glass and accessibility

- Install an app built with Xcode 26+ on a compatible iOS device.
- Inspect navigation, tab bars, toolbars, sheets, forms, and buttons for native Liquid Glass in Light and Dark Mode.
- Confirm custom trackpad/input backgrounds do not obscure system navigation materials.
- Run VoiceOver labels/actions, Dynamic Type, contrast, Reduce Motion, and keyboard focus checks; confirm all controls remain usable.

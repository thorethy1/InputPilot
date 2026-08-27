# InputPilot hardware E2E test plan

## v0.8.0 BLE OTA release gate (Waveshare ESP32-S3-Zero, 4 MB)

This gate cannot be replaced by simulator or host tests. Record board revision, iPhone/iOS version, source/target firmware versions, and observed USB HID result.

1. Run `esptool --chip esp32s3 erase-flash`; do not rely on NVS, OTA metadata, or any data from an older flash.
2. Perform an initial USB flash with `InputPilot-v0.8.0-initial-flash.bin`. Repeat the clean-install test with the individual release images (`bootloader.bin`, `partitions.bin`, `boot_app0.bin`, and `firmware.bin`) at the offsets in `initial-flash-manifest.json`.
3. For each method, power-cycle and verify USB HID enumeration as **InputPilot S3**, BLE advertising/metadata, product/board/version identity, `otaSchema == 1`, the running `ota_0` partition, and the expected two-slot partition table. Confirm `boot_app0.bin` is present in the package.
4. Connect the iPhone over BLE, complete token authentication when configured, and perform the first OTA after the erased-flash installation. Verify that the inactive slot is used and becomes bootable without pre-existing OTA data.
5. Confirm 100% transfer, SHA-256 verification, reboot, automatic reconnect, expected new version, and working USB mouse/keyboard/release-all.
6. Repeat with a token failure, invalid image, oversized declaration, wrong SHA-256, and explicit Cancel; no failed case may select the pending partition.
7. Start another update and disconnect Bluetooth near 50%. Power-cycle the ESP32, verify that the prior firmware and USB HID still work, then complete a fresh OTA successfully.
8. Exercise BLE-only, Wi-Fi-only, and combined Automatic control plus small/large iPhone layouts, portrait/landscape where supported, Light/Dark Mode, Dynamic Type, VoiceOver, Reduce Motion, and Increased Contrast.

Attach the completed observation record to the v0.8.0 release. If physical hardware or a signed iOS build is unavailable, mark this gate **not run**; do not infer success from compilation.

Record the firmware/app commit, board device ID, host OS/layout, iPhone/iOS version, Xcode version, transport, and pass/fail evidence for every run. Use the v0.8.0 release-candidate firmware and an app built with Xcode 26 or newer. Release results belong in `HARDWARE_E2E_RESULTS_0.8.0.md`.

## USB HID and transports

### BLE visibility, onboarding, and reconnect

- Boot once in `wifi+ble` and once in BLE-only mode. In each mode capture the serial log and verify GATT services started, advertising payload/scan-response sizes were logged, and `BLE advertising started` appears with no `ble:*fail` status.
- Inspect the legacy advertisement with a BLE scanner: manufacturer data must be exactly ASCII `IP` plus the 12-lowercase-hex device ID. The scan response must contain `usb-hid-s3`; advertised 128-bit service UUIDs are intentionally not required.
- In the iOS app choose Add Device → Bluetooth → Scan Nearby. Verify the board appears with the same device ID, OTA metadata is readable, and the device can be saved.
- Close/reopen the saved device, verify the broad scan selects exactly the matching manufacturer identity, then verify BLE authentication and HID control.
- Disconnect from the iPhone and verify the firmware logs a successful advertising restart. Reconnect the saved device without rebooting the ESP32.
- With Wi-Fi connected and BLE active, repeat onboarding, HID control, OTA metadata/status read, disconnect, and reconnect. Confirm TCP/REST and Wi-Fi setup still work afterward.
- From the Firmware screen verify BLE OTA capability and metadata, then begin an update far enough to receive `READY` before cancelling safely (or complete the release-candidate OTA test below).

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

# InputPilot hardware E2E test plan

## v0.8.2 HID/BLE test-candidate gate (Waveshare ESP32-S3-Zero, 4 MB)

This gate cannot be replaced by simulator or host tests. Record board revision, iPhone/iOS version, source/target firmware versions, and observed USB HID result.

1. Run `esptool --chip esp32s3 erase-flash`; do not rely on NVS, OTA metadata, or any data from an older flash.
2. Perform an initial USB flash with `InputPilot-v0.8.2-initial-flash.bin`. Repeat the clean-install test with the individual release images (`bootloader.bin`, `partitions.bin`, `boot_app0.bin`, and `firmware.bin`) at the offsets in `initial-flash-manifest.json`.
3. For each method, power-cycle and verify USB HID enumeration as **InputPilot S3**, BLE advertising/metadata, product/board/version identity, `otaSchema == 1`, the running `ota_0` partition, and the expected two-slot partition table. Confirm `boot_app0.bin` is present in the package.
4. Connect the iPhone over BLE, complete token authentication when configured, and perform the first OTA after the erased-flash installation. Verify that the inactive slot is used and becomes bootable without pre-existing OTA data.
5. Confirm 100% transfer, SHA-256 verification, reboot, automatic reconnect, expected new version, and working USB mouse/keyboard/release-all.
6. Repeat with a token failure, invalid image, oversized declaration, wrong SHA-256, and explicit Cancel; no failed case may select the pending partition.
7. Start another update and disconnect Bluetooth near 50%. Power-cycle the ESP32, verify that the prior firmware and USB HID still work, then complete a fresh OTA successfully.
8. Exercise BLE-only, Wi-Fi-only, and combined Automatic control plus small/large iPhone layouts, portrait/landscape where supported, Light/Dark Mode, Dynamic Type, VoiceOver, Reduce Motion, and Increased Contrast.

If physical hardware or a signed iOS build is unavailable, mark this gate **NOT RUN**; do not infer success from compilation or release publication.

Record the firmware/app commit, board device ID, host OS/layout, iPhone/iOS version, Xcode version, transport, and pass/fail evidence for every run. Use the v0.8.2 test-candidate firmware and an app built with Xcode 26 or newer. Results belong in `HARDWARE_E2E_RESULTS_0.8.2.md`.

## USB HID and transports

### BLE visibility, onboarding, and reconnect

- Boot once in `wifi+ble` and once in BLE-only mode. In each mode capture the serial log and verify GATT services started, advertising payload/scan-response sizes were logged, and `BLE advertising started` appears with no `ble:*fail` status.
- Inspect the legacy advertisement with a BLE scanner: manufacturer data must be exactly ASCII `IP` plus the 12-lowercase-hex device ID. The scan response must contain `usb-hid-s3`; advertised 128-bit service UUIDs are intentionally not required.
- In the iOS app choose Add Device → Bluetooth → Scan Nearby. Verify the board appears with the same device ID, OTA metadata is readable, and the device can be saved.
- Close/reopen the saved device, verify the broad scan selects exactly the matching manufacturer identity, then verify BLE authentication and HID control.
- Disconnect from the iPhone and verify the firmware logs a successful advertising restart. Reconnect the saved device without rebooting the ESP32.
- With Wi-Fi connected and BLE active, repeat onboarding, HID control, OTA metadata/status read, disconnect, and reconnect. Confirm TCP/REST and Wi-Fi setup still work afterward.
- From the Firmware screen verify BLE OTA capability and metadata, then begin an update far enough to receive `READY` before cancelling safely (or complete the release-candidate OTA test below).

### Diagnostics and version information

- Open Settings → Firmware Logs for a BLE-only device. Verify recent boot logs appear first, new logs arrive live, Pause/Resume works, reconnect resumes logging, and closing the view removes the notification subscription.
- Repeat with a Wi-Fi-only device and verify authenticated `GET /api/logs` supplies the same bounded recent log format.
- Exercise All, BLE, Wi-Fi, OTA, HID, USB, and Warnings / Errors filters; verify Clear affects only the local display and Copy All / text-file export work.
- During BLE OTA verify diagnostics notifications pause rather than competing with the transfer, then resume afterward.
- Confirm Settings About shows app version/build from the installed bundle and the selected device's last-known firmware, protocol, and OTA schema. Confirm Device Detail shows the same software values.
- Compare the shown firmware version with the flashed image and inspect exported diagnostics for credentials. SSID/IP may appear; Wi-Fi passwords, API/auth tokens, and private credentials must not.

### Transport-neutral OTA and recovery

- With both transports available and Connection Mode Automatic, install `firmware.bin`; verify the UI says `Wi-Fi`, upload progress/speed advance, the device reboots, `/api/status` reconnects, and identity/version/schema verification completes.
- Repeat in Prefer Bluetooth and Bluetooth Only; verify the existing BLE START/DATA/FINISH/ACK protocol remains compatible and the UI says `Bluetooth`.
- Verify Prefer Wi-Fi, Wi-Fi Only, BLE-only, and Wi-Fi-only devices select only permitted/capable transports, with fallback only when the selected Connection Mode allows it.
- Record `/api/diagnostics` before and after same-version OTA. Verify `runningPartition` and `bootPartition` switch together from `ota_0` to `ota_1` (or vice versa).
- During Wi-Fi OTA disconnect BLE and confirm the HTTP upload continues. During BLE OTA disable Wi-Fi and confirm BLE transfer continues.
- Start a second BLE or Wi-Fi OTA while one is receiving; verify `update_in_progress`, no second partition writer, and the first session remains healthy.
- Abort each transport mid-transfer, power-cycle, and verify the previous firmware remains bootable. Then retry successfully.
- Attempt initial-flash.bin, bootloader.bin, partitions.bin, boot_app0.bin, wrong SHA/size/version/product/board/protocol/schema and an interrupted upload; every case must fail without selecting a boot partition.

### HID executor and BLE reboot regression

- Test transports in isolation and in this order: `hidtest mouse` / `hidtest keyboard` over USB serial, REST mouse/keyboard, TCP mouse/keyboard, then BLE mouse/keyboard. For every event compare the app event ID with firmware receive, decode, queue, execute counters and physical USB-host reaction; a connected socket alone is not a pass.
- Boot in `wifi+ble`, record the new `reset_reason=...` line, connect BLE without sending input, and verify stability for at least 30 seconds.
- Send one BLE mouse move, then continuous trackpad movement for 30 seconds. Verify movement remains responsive, queue-overflow warnings do not repeat, and the ESP does not reboot.
- Test left/right/middle click, keyboard typing, key combinations, and drag with a final button-up. Verify no stuck key or mouse button.
- Hold a mouse button and disconnect BLE. Verify the queued `releaseAll` executes and reconnect/advertising remain healthy.
- Send Wi-Fi control after BLE control, BLE control after Wi-Fi control, then rapidly alternate transports for 30 seconds. Verify ordering remains usable, USB HID stays enumerated, and no reboot occurs.
- If a reboot occurs, capture `reset_reason`, the last HID queue/executor warnings, uptime, and whether a panic/core dump is reported by the serial boot log.
- Repeat in Bluetooth Only, Wi-Fi Only, and with automatic fallback disabled for diagnosis. Then enable fallback and verify mouse movement may be dropped, while uncertain button/key events are not resent and are recovered with `releaseAll`.
- Open Settings → App Logs and verify event ID, candidate transports, selection, BLE UUID/properties/write type/length, write result, disconnect error and fallback decision. Export diagnostics and verify app/firmware versions and commits, reset reason and HID counters are present without typed text or credentials.

### Physical-device transport merge

- A: clear app data, add by Wi-Fi, then discover/add Bluetooth. Verify one StoredDevice remains, friendly name/token/IP/mDNS are preserved, and both connections are shown.
- B: clear app data, add by Bluetooth, then provision/discover Wi-Fi. Choose “Add Wi-Fi to existing InputPilot”; verify IP/mDNS and Wi-Fi capabilities are merged into the same device ID without an Already Added error.
- Repeat discovery for a transport already recorded. Verify the app reports that transport as already configured and never creates a second device row.
- Open Firmware Logs, load history, then generate live logs and reconnect BLE. Verify each `(sequence, line)` appears once and polling `/api/logs` does not duplicate existing rows.

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

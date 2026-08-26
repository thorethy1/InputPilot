# InputPilot 0.6 hardware E2E test plan

Record the firmware/app commit, board device ID, host OS/layout, iPhone/iOS version, Xcode version, transport, and pass/fail evidence for every run. Use firmware 0.6.0 and an app built with Xcode 26 or newer.

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

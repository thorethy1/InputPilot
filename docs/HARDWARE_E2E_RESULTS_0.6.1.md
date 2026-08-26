# InputPilot 0.6.1 hardware release validation

Status: **MANUAL REQUIRED**. This Codex environment has no ESP32 board, USB HID
host, iPhone, Xcode 26 device runner, second board, or signing credentials.
No physical result below is represented as passed.

Record one row per executed configuration. Replace `MANUAL REQUIRED` only with
observed evidence from the listed firmware and app commits.

| Test | Firmware commit | App commit | ESP32 board | Host OS | Host keyboard layout | iPhone / iOS | Transport | Result | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Mouse move; left/right/middle/double click; scroll; drag start/move/end | TBD | TBD | TBD | TBD | German QWERTZ | TBD | BLE | MANUAL REQUIRED | Verify no stuck button. |
| German keys: y z ä ö ü Ä Ö Ü ß @ € \\ \| ? ! / ^ | TBD | TBD | TBD | TBD | German QWERTZ | TBD | BLE | MANUAL REQUIRED | Compare visible host output. |
| US a-z, A-Z, digits, shifted symbols | TBD | TBD | TBD | TBD | US QWERTY | TBD | BLE | MANUAL REQUIRED | Compare visible host output. |
| Keyboard, mouse, drag, scroll, macro | TBD | TBD | TBD | TBD | Both | TBD | TCP only | MANUAL REQUIRED | Reboot and reconnect included. |
| Basic keyboard and mouse fallback | TBD | TBD | TBD | TBD | Both | TBD | REST | MANUAL REQUIRED | Force BLE/TCP unavailable. |
| Concurrent radio stability | TBD | TBD | TBD | TBD | Both | TBD | Wi-Fi + BLE | MANUAL REQUIRED | Confirm both remain active. |
| Correct `CONTROL_API_TOKEN` | TBD | TBD | TBD | TBD | N/A | TBD | BLE / TCP / REST | MANUAL REQUIRED | Each transport must execute HID only after confirmation. |
| Wrong token | TBD | TBD | TBD | TBD | N/A | TBD | BLE / TCP / REST | MANUAL REQUIRED | UI says Authentication failed; no HID action. |
| Token change and device reboot | TBD | TBD | TBD | TBD | N/A | TBD | BLE / TCP | MANUAL REQUIRED | Verify state reset and reconnect. |
| Two-device identity / cross-control | TBD | TBD | Two boards required | TBD | N/A | TBD | BLE + Wi-Fi | MANUAL REQUIRED – second board | Name boards Office and Living Room; prove isolation. |
| Disconnect Bluetooth during drag/modifier/macro | TBD | TBD | TBD | TBD | Both | TBD | BLE | MANUAL REQUIRED | Playback stops; release-all attempted; no stuck input. |
| Disable Wi-Fi during drag/modifier/macro | TBD | TBD | TBD | TBD | Both | TBD | TCP | MANUAL REQUIRED | No mid-sequence continuation on BLE/REST. |
| ESP32 reboot during drag/modifier/macro | TBD | TBD | TBD | TBD | Both | TBD | BLE / TCP | MANUAL REQUIRED | No stuck input after reconnect. |
| Background app during drag/modifier/macro | TBD | TBD | TBD | TBD | Both | TBD | BLE / TCP | MANUAL REQUIRED | UI stops and release-all is attempted. |
| Liquid Glass smoke test, Light and Dark | N/A | TBD | N/A | N/A | N/A | Compatible device / TBD | N/A | MANUAL REQUIRED | Xcode 26+; navigation, tabs, toolbars, forms, sheets, buttons. |
| Signed `InputPilot.ipa` workflow | N/A | TBD | N/A | N/A | N/A | Registered device / TBD | N/A | MANUAL REQUIRED | Run `iOS Signed Build`; artifact only, never a release asset. |

## Evidence checklist

- Attach the CI run URL and signed-build run URL without exposing secrets.
- Record serial logs with token values redacted; firmware replies may contain
  only `auth ok` or `auth failed`.
- For failure tests, record whether playback stopped, release-all was attempted,
  the UI stopped, and the host showed no stuck mouse button or modifier.
- Record board device IDs for the two-device test, but never API tokens or Wi-Fi
  credentials.

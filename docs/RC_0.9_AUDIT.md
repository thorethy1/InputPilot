# 0.9 release candidate audit — 2026-09-07

Status: implementation work prepared; **release gate not passed**. This is a
source audit of `ROADMAP.md`, `IMPLEMENTATION_0.9.md` and the current code, not a
claim of physical-device verification. Release identity remains managed by the
existing beta/release workflows.

## Implemented in this change

- Control opens Trackpad/Keyboard/Presets/Macros directly for the active device.
  Device switching creates the correct device-specific controller and is disabled
  during macro playback or while a recording still needs saving.
- Settings has a dedicated Appearance page with System/Light/Dark and accent
  colors. The Standard/Rounded preference and its app-wide overrides are removed.
  Device connection/firmware internals are grouped in disclosure controls.
- Active-device and transport pickers observe accent changes locally, apply the
  current tint and recreate only their native picker control. Device/transport
  bindings and navigation remain intact, including when editing a custom color.
- Control retains connection recovery actions, identifies the active transport,
  adapts its section selector at accessibility text sizes and shows a recording
  indicator outside the Macros section.
- Macro library: search, event counts, estimated time per repeat, description,
  rename/edit, duplicate, confirmed delete, progress, repeat/start-delay/speed
  controls and explicit Starting/Running/Stopping/Completed/Cancelled/Failed states.
- Macro event editor: reorder, delete, pauses, text, key combinations, recorded
  mouse input and Secret selection. Raw keyboard report values remain unchanged;
  their timing and position can be edited. Editing uses a draft until Save.
- Playback snapshots events, rejects invalid/empty timelines and duplicate runs,
  paces fast sequences, releases held input after repeats/failure/cancellation and
  remains busy until cleanup finishes. Cancelling a start delay sends no input.
- Macro Secrets store UUID references in the existing event Data, resolve values
  from Keychain at playback and survive secret renames. Missing references are
  shown in the editor; deleting a secret lists affected macros. Preset execution
  is excluded from macro capture, including secret-derived keyboard reports.
- Release-all no longer suppresses a second request within 500 ms: new held input
  may have arrived since the first request.
- Device Details → Wi-Fi Access Point → Disable AP controls a persistent firmware
  preference. Saved station connections and Bluetooth remain usable. Disabling
  AP also suppresses the hotspot with no configured networks; saved networks are
  retried at the normal fallback retry interval. Network deletion preserves the
  AP preference. OTA rejects concurrent changes.

## Compatibility

`HIDMacro` retains its existing SwiftData attributes and type name. Existing
`offset`/`event` JSON remains readable; the optional `secretID` field does not
require a SwiftData schema change. The new store-reopen regression test covers
legacy event decoding and the added reference inside the existing Data field.
A full upgrade from a previously shipped app still needs the device migration gate.

AP feature support is probed using authenticated `WIFI AP GET`, rather than
expanding the already nearly full 512-byte BLE discovery metadata. Older firmware
returns an unsupported-command response and the UI requests a firmware update.
No app/firmware version equality requirement was introduced.

## Remaining implementation gaps against the roadmap

| Area | Evidence and remaining work |
| --- | --- |
| Quick Shortcuts | `KeyboardView.swift` still uses `QuickShortcut.defaults`. Create/edit/rename/duplicate/delete/reorder/favorite management and reusable Secret-backed shortcut actions remain open. Presets already cover several reusable-action needs, but do not complete this separate roadmap item. |
| App Intents | Present: Run Preset, Connect Device, Check Device Status, Send Keyboard Shortcut, Send Text. Missing: Run InputPilot Shortcut, Run Macro, Switch Device, Start Mouse Move, Stop Mouse Move. Macro playback now exposes completion but is not wired into an AppEntity/intent. |
| Downgrade protection | The release evaluator avoids suggesting an older published release. Firmware OTA start/image validation does not compare the incoming version against the installed version. Firmware enforcement and the manual-file app path still need work. |
| OTA presentation | Progress/integrity/compatibility handling exists. Release notes before installation and the complete compatibility/manual-update UX audit remain open. |
| UI polish | The changed Control, Macro, Appearance and Device Details screens need real rendered review. An app-wide pass over empty/loading/error states, Dynamic Type, VoiceOver, contrast, Reduce Motion and safe areas remains open. |
| Trackpad and disconnects | Gesture implementations exist; physical pointer/scroll/drag/pinch tuning and proof of held-input cleanup across BLE/Wi-Fi disconnects remain open. |
| Repository presentation | The repository already has a logo and older device screenshots. New screenshots of the current UI, the README feature refresh and current architecture illustration remain open. |
| Data and lifecycle | Physical Keychain CRUD, existing-install migration/restore, app-switcher exposure, background/suspended/terminated App Intent behavior and Siri remain unverified. The existing in-memory fallback on store-open failure is not evidence of successful migration. |

## Verification in this workspace

| Check | Result |
| --- | --- |
| `pio test -d usb-hid-s3 -e native` | PASS: 109 tests, including AP persistence/apply ordering and storage-failure handling. |
| `pio run -d usb-hid-s3 -e esp32s3` | PASS: firmware and initial-flash image generated; application image 1,556,656 / 1,966,080 bytes, 409,424 bytes free in OTA slot. |
| Xcode project references | Parsed and new source/test files registered in their targets. |
| Swift syntax review | New Macro controller/view/tests parsed without syntax errors. Existing parser limitations in unrelated Swift expressions are unchanged. This does not type-check SwiftUI or SwiftData. |
| iOS build / XCTest | NOT RUN: this workspace is Linux and has no Xcode/iOS SDK. New tests cover legacy event/store compatibility, repeats, invalid timing, missing Secrets, offline/send failure, cancellation, duplicate execution, release-all and exclusion of preset Secrets from capture. Run the existing macOS CI before release. |
| Physical ESP32 + iPhone | NOT RUN. No hardware result is claimed. |

## Focused manual verification

- [ ] Open Control with zero, one and multiple devices. Switch active device;
      confirm input goes only to that device and old playback stops.
- [ ] Record mouse/keyboard input; save, relaunch, rename, duplicate, edit pauses,
      edit text/keys, reorder and delete events. Cancel editing without saving.
- [ ] Play at every speed, with 1/multiple/infinite repeats and a start delay.
      Cancel during the delay, a held mouse button, typing, scrolling and a repeat.
      Disconnect each transport while input is held. Confirm no stuck input.
- [ ] Add a Secret reference; rename/replace/delete the Secret. Verify current
      values are used, missing references fail clearly, and stored event data,
      recordings and logs contain no Secret value or secret-derived key reports.
- [ ] Toggle Disable AP over BLE and authenticated Wi-Fi, including while connected
      to the hotspot. Reconnect over BLE if the hotspot closes. Confirm status.
- [ ] Power-cycle with AP disabled: no networks, unreachable saved networks and a
      reachable network. Confirm no hotspot appears and station retries continue.
- [ ] Delete all networks with AP disabled; reconnect via BLE, re-enable AP and
      confirm the hotspot returns. Verify old firmware and OTA-busy behavior.
- [ ] Change preset and custom accent colors repeatedly without restarting. Verify
      Active Device in Settings/Firmware/Diagnostics and the default/current
      transport selectors use the new color; selection and navigation persist.
- [ ] Review Appearance and all changed screens in Light/Dark/System, accessibility
      text sizes, VoiceOver, Reduce Motion and smallest/largest supported iPhones.

All required gates in `IMPLEMENTATION_0.9.md` remain authoritative. Unrun hardware,
iOS and accessibility checks must not be treated as passing RC/stable criteria.

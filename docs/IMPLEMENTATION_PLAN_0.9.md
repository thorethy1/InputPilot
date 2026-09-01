# InputPilot 0.9 Implementation Plan

Status: started on 2026-09-01
Target: 0.9.0 release candidate on 2026-10-26, release on 2026-11-06

Development takes place on `beta` and is published as versioned prereleases.
After the release gate passes, `beta` is merged into `main` and promoted to the
stable `0.9.0` channel. See [Stable and Beta Release Channels](RELEASE_CHANNELS.md).

## Release strategy

0.9 is an iOS experience and reliability release. Protocol changes are allowed only
when they are required for safe input release, compatibility enforcement, or a
capability that cannot be implemented correctly in the app alone.

Work is split into vertical slices. Every slice must include its UI states,
accessibility, failure behavior, automated coverage where practical, and a short
manual verification checklist. Existing partial implementations are hardened rather
than rebuilt.

## Schedule

| Dates | Milestone | Deliverables | Exit criteria |
| --- | --- | --- | --- |
| Sep 1-4 | M0: Foundation | Design tokens, semantic colors, System/Light/Dark appearance, accent choices, 0.9 audit | Appearance changes live without changing status/destructive meaning; current tests remain green |
| Sep 7-18 | M1: Devices and connection | Active-device selection, consistent high-level connection banner, recovery actions, permissions, polished offline/loading/error states, settings/diagnostics split | Devices, Details, Control and Settings show the same live state; fallback never looks like a total outage |
| Sep 21-Oct 2 | M2: Trackpad | Explicit gesture state machine, acceleration and low-speed precision, smooth/natural/inertial scrolling, secondary click, drag safety, first-use hints, sensitivity | No conflicting gestures or stuck mouse buttons; real-device trackpad checklist passes |
| Oct 5-9 | M3: Keyboard and presets | Intentional text composer, explicit clipboard paste, Release All Keys, compact shortcuts, preset execution state and duplicate-run guard, rename/duplicate/reorder polish | Success/failure/loading states are visible; clipboard matrix and preset execution tests pass |
| Oct 12-16 | M4: Macros and secrets | Macro progress/cancel/failure states, safe release paths, event editing/reordering where safe, Keychain-backed secret model and references | Cancellation/failure always releases input; secret values never enter SwiftData, logs or diagnostics |
| Oct 19-23 | M5: Firmware, adaptive UI and presentation | Compatibility metadata audit, release notes/result UX, Dynamic Type/safe-area pass, repository screenshots and architecture diagram | Compatibility errors are actionable; required screen-size and appearance reviews complete |
| Oct 26-Nov 6 | RC and release gate | Full CI, physical BLE/Wi-Fi HID and OTA matrix, rollback test, accessibility review, bug fixes only | Every ROADMAP 0.9 release-gate item is recorded as pass or an explicit release blocker |

## Current implementation audit

The repository already contains useful parts of the 0.9 scope:

- Native tab/navigation/form structure and several `ContentUnavailableView` states.
- Live Wi-Fi/Bluetooth presence aggregation and automatic transport fallback rules.
- Trackpad move, scroll, tap/double-tap, long-press secondary click and drag release.
- One-shot keyboard modifiers, keyboard layouts and safety `releaseAll` support.
- Preset favorite, duplicate, delete and drag ordering.
- Macro recording, repeats, start delay, cancellation and release-all behavior.
- Firmware compatibility validation, detailed progress states and integrity checks.

These are starting points, not release-gate completion. The largest risk is the
current concentration of control UI, transport code and models in `HIDControl.swift`;
each milestone should extract only the area it actively changes so that refactoring
does not become a parallel rewrite.

## Milestone progress

### M0: Foundation

- [x] Shared spacing/radius tokens and semantic status colors.
- [x] System, Light and Dark appearance choices.
- [x] User-selectable accent colors that do not redefine status or destructive meaning.

### M1: Devices and connection

Started early on 2026-09-01 after the beta release channel became operational.

- [x] Remember and reconcile one active device across Devices, Control, Firmware and Settings.
- [x] Mark the active device in the saved-device list and provide native swipe/context switching actions.
- [x] Use one high-level Connected/Connecting/Offline/Attention Required presentation in normal UI.
- [x] Offer retry, app-permission and USB-trust recovery from the shared connection banner.
- [x] Move technical device/build/log/export information behind Diagnostics & Advanced.
- [ ] Verify Bluetooth-denied, Bluetooth-off, Wi-Fi-only and automatic-fallback states on physical hardware.
- [ ] Audit unexpected disconnect paths and prove held keyboard/mouse input is released.
- [ ] Complete VoiceOver, Dynamic Type, Light/Dark and Reduce Motion review for all M1 screens.

The manual gate for this slice is tracked in
[M1 Device and Connection Checklist](M1_DEVICE_CONNECTION_CHECKLIST.md).

## Cross-cutting definition of done

For every user-triggered asynchronous action:

1. The normal, pressed/loading, disabled, success and failure states are defined.
2. Duplicate execution is prevented when repeating the action would be unsafe.
3. Errors state a short reason and offer recovery when one exists.
4. VoiceOver has a useful label/value and the target is at least 44x44 points.
5. Dynamic Type, Reduce Motion, Light Mode and Dark Mode behavior are considered.
6. Disconnect and cancellation paths release held keys and mouse buttons.
7. Sensitive input is neither logged nor persisted unless explicitly required.

## Tracking and release decisions

- Keep `ROADMAP.md` as product scope; use this document for dates and implementation order.
- Keep the app and firmware independently versioned. Do not bump to 0.9.0 until the
  release workflow is run for the approved release commit.
- Add each completed slice to `CHANGELOG.md` under `Unreleased`.
- Hardware-only gates must be recorded in a dated result document under `docs/`.
- Any gate that cannot pass by 2026-11-06 moves the release date; it is not silently
  removed from scope.

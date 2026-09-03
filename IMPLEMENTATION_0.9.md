# InputPilot 0.9 Implementation Plan

This document defines the implementation strategy for the InputPilot 0.9 generation.

`ROADMAP.md` defines the product scope and desired result. This document defines the implementation order, architecture, verification strategy and release gate.

0.9 is primarily an iOS experience, automation and reliability release. Existing working functionality should be hardened rather than rebuilt without reason. Protocol or firmware changes are appropriate when required for safe input release, transport reliability, compatibility enforcement, OTA safety or capabilities that cannot be implemented correctly in the app alone.

Development should continue through the existing beta/prerelease workflow. See [Stable and Beta Release Channels](RELEASE_CHANNELS.md).

## Engineering principles

Work is organized by product feature rather than artificial calendar milestones. Each feature should include its UI states, accessibility, failure behavior, automated coverage where practical and a short manual verification checklist.

For every user-triggered asynchronous action:

- define normal, loading, disabled, success and failure behavior
- prevent unsafe duplicate execution
- provide a short actionable error where recovery exists
- support useful VoiceOver labels and appropriate interaction targets
- consider Dynamic Type, Reduce Motion, Light Mode and Dark Mode
- guarantee held keyboard/mouse input cleanup after relevant disconnect, cancellation and failure paths
- never log or unnecessarily persist sensitive input

Existing completed work remains completed. Checked items below reflect work already implemented by Codex and should not be reopened without a concrete regression or architectural reason.

---

# 1. Foundation & Native UI

## Goal

Make InputPilot feel like a polished native iOS application and establish shared visual foundations for the remaining 0.9 work.

## Completed

- [x] Shared spacing/radius tokens and semantic status colors.
- [x] System, Light and Dark appearance choices.
- [x] User-selectable accent colors that do not redefine status or destructive meaning.

## Remaining work

- [ ] Apply the design system consistently across remaining major screens and controls.
- [ ] Define consistent normal/pressed/loading/disabled/success/failure presentation for major controls.
- [ ] Prefer native SwiftUI components and navigation patterns where suitable.
- [ ] Use Liquid Glass appropriately where supported without sacrificing clarity or compatibility.
- [ ] Add appropriate haptic feedback to important control interactions.
- [ ] Ensure important state is never communicated by color alone.
- [ ] Complete app-wide Dynamic Type, VoiceOver, contrast, interaction-target and Reduce Motion review.
- [ ] Review smallest supported iPhone, largest current iPhone and useful landscape layouts.
- [ ] Remove major safe-area and Tab Bar overlap issues.
- [ ] Polish empty, loading, offline and error states using native patterns such as `ContentUnavailableView` and `ProgressView` where appropriate.

## Architecture notes

Keep semantic state colors separate from user-selectable branding/accent colors. Avoid introducing custom components when native SwiftUI behavior already solves the interaction well.

## Exit criteria

The major 0.9 screens share one coherent visual language, remain usable in Light/Dark/System appearance and adapt correctly to supported layouts and accessibility settings.

---

# 2. Devices, Connection & Transport Safety

## Goal

A normal user should immediately understand whether InputPilot is usable without needing to understand BLE, TCP, REST or transport internals. BLE and Wi-Fi should behave as interchangeable capable transports behind the same product experience wherever the protocol supports it.

## Completed

- [x] Remember and reconcile one active device across Devices, Control, Firmware and Settings.
- [x] Mark the active device in the saved-device list and provide native swipe/context switching actions.
- [x] Use one high-level Connected/Connecting/Offline/Attention Required presentation in normal UI.
- [x] Offer retry, app-permission and USB-trust recovery from the shared connection banner.
- [x] Move technical device/build/log/export information behind Diagnostics & Advanced.

## Remaining work

- [ ] Verify Bluetooth-denied, Bluetooth-off, Wi-Fi-only and automatic-fallback states on physical hardware.
- [ ] Verify BLE-only operation exposes all supported InputPilot control functions rather than becoming a reduced emergency mode.
- [ ] Verify Wi-Fi-only operation exposes all supported InputPilot control functions where technically applicable.
- [ ] Ensure automatic fallback never looks like a total outage while another transport remains usable.
- [ ] Ensure the currently active control transport remains identifiable without making normal UI overly technical.
- [ ] Audit authentication after adding Wi-Fi and transport transitions so a newly configured network becomes usable without inconsistent authentication state.
- [ ] Audit reconnect behavior after prolonged Wi-Fi failure and ensure BLE can recover/become active when available.
- [ ] Audit unexpected disconnect paths and prove held keyboard/mouse input is released.
- [ ] Complete VoiceOver, Dynamic Type, Light/Dark and Reduce Motion review for all connection screens.

## Input safety

Centralize or strengthen shared cleanup semantics for:

- BLE disconnect
- Wi-Fi disconnect
- active transport failure
- transport switch
- timeout
- failed/cancelled Shortcut, Preset or Macro
- relevant app lifecycle interruption

Provide reliable shared concepts equivalent to:

`Release All Keys`

`Release All Buttons`

Where practical, execution should follow:

`begin → execute → success / failure / cancel → guaranteed cleanup`

Features should not each maintain independent cleanup implementations.

## Architecture notes

Normal UI should consume coherent device-level state rather than independently interpreting raw transport state on every screen. Transport selection, authentication and fallback should have clear ownership.

Keep low-level protocol, OTA schema, build, transport and raw diagnostics in Advanced/Diagnostics.

## Exit criteria

Devices, Details, Control, Firmware and Settings agree on live device state. BLE-only, Wi-Fi-only and fallback behavior pass physical-hardware verification. No known disconnect path can leave a held key or mouse button behind.

The existing manual M1 checklist may continue to be used where applicable: [M1 Device and Connection Checklist](M1_DEVICE_CONNECTION_CHECKLIST.md).

---

# 3. Trackpad

## Goal

Make the InputPilot trackpad behave as closely as practical to a real laptop trackpad while prioritizing predictable HID behavior and safe release.

## Existing implementation

The current code already contains useful trackpad behavior including movement, scrolling, tap/double-tap, long-press secondary click and drag release. Harden and extend this rather than rebuilding working behavior without reason.

## Remaining work

- [x] Define/refine explicit mutually exclusive gesture states where useful: `idle → moving → scrolling → clicking → dragging → zooming`.
- [x] Improve low-speed pointer precision.
- [ ] Improve pointer smoothing and acceleration curve.
- [x] Improve two-finger scrolling.
- [x] Add/tune natural scrolling option.
- [x] Add/tune momentum or inertial scrolling where it improves the experience.
- [ ] Verify tap-to-click and double-click behavior.
- [ ] Verify press/hold and/or two-finger secondary click behavior.
- [ ] Make drag-and-drop reliable, including guaranteed drag release.
- [x] Add pinch-to-zoom where the HID/protocol path can support it correctly.
- [x] Add configurable sensitivity.
- [x] Add subtle haptic feedback where useful.
- [x] Add lightweight first-use gesture hints without permanently cluttering the trackpad.
- [x] Keep explicit click controls as a reliable fallback if they remain useful.

## Exit criteria

There are no conflicting gestures or known stuck-drag states. Movement, precision, scrolling, secondary click, drag/release and implemented zoom behavior pass a real ESP32-S3/computer hardware checklist.

---

# 4. Keyboard & InputPilot Shortcuts

## Goal

Turn keyboard control and InputPilot's internal Shortcuts into one polished, safe, first-class control experience.

## Keyboard

The current implementation already includes keyboard layouts, one-shot modifiers and `releaseAll` support. Preserve and harden these capabilities.

- [ ] Redesign keyboard shortcut controls into compact native layouts rather than stretched full-width buttons.
- [ ] Improve modifier presentation and sticky/latched behavior where useful.
- [ ] Keep an explicit `Release All Keys` safety action.
- [ ] Ensure modifiers and held keys are released after all relevant error/disconnect paths.
- [ ] Improve key/send visual feedback.
- [ ] Improve keyboard dismissal and text-composer behavior.
- [ ] Add explicit `Paste Clipboard` action that reads the clipboard only after user interaction.
- [ ] Paste clipboard contents into the editable field before transmission so the user can review/edit them.
- [ ] Handle empty/unavailable clipboard clearly.
- [ ] Never unnecessarily log or persist clipboard contents.
- [ ] Preserve intentional field clearing after text is sent, with appropriate success/failure feedback.

Clipboard verification must cover normal, empty, multiline, special-character and large input plus unavailable/denied cases where applicable.

## InputPilot Shortcuts redesign

Shortcuts are not merely keyboard buttons. Review both their visual presentation and their data/execution model.

- [ ] Support Create, Edit, Rename, Duplicate, Delete, Reorder and Favorite/Unfavorite.
- [ ] Use native context menus, swipe actions and compact grid/list presentation where appropriate.
- [ ] Provide clear Ready/Running/Completed/Failed execution feedback.
- [ ] Prevent unsafe duplicate execution.
- [ ] Support reusable actions such as key, key combination, modifiers, text and Secret references where appropriate.
- [ ] Guarantee Shortcut failure cannot leave modifiers, keys or mouse buttons held.

## Shared action architecture

As this feature is implemented, establish or evolve toward a shared action/execution abstraction if it materially improves the current architecture.

Conceptually:

`UI / App Intent → InputPilotAction → Execution Service → Active Transport → ESP32`

Shortcuts, Presets, Macros and future App Intents should not each implement independent HID/transport stacks.

The exact Swift type hierarchy is intentionally not prescribed. Codex should fit the abstraction to the existing codebase and avoid an unnecessary full rewrite.

## Exit criteria

Keyboard input feels intentional and safe, clipboard behavior passes its verification matrix, internal Shortcuts have a coherent management/execution experience, and execution uses shared transport/action infrastructure where beneficial.

---

# 5. Presets, Macros & Secrets

## Goal

Unify reusable InputPilot automation around safe execution and a Keychain-backed Secrets system without unnecessarily rewriting stable Preset/Macro behavior.

## Existing implementation

The repository already contains useful Preset favorite/duplicate/delete/drag ordering behavior and Macro recording/repeats/start-delay/cancellation/release-all behavior. Treat these as working foundations.

## Presets

- [ ] Ensure Run works reliably.
- [ ] Improve cards/rows and management consistency.
- [ ] Support Rename, Duplicate, Edit, Delete, ordering and favorites coherently.
- [ ] Provide Run/Running/Completed/Failed feedback.
- [ ] Prevent unsafe duplicate execution.
- [ ] Support Secret references.
- [ ] Guarantee failure cleans up held input.

## Macros

- [ ] Improve list/card presentation and management.
- [ ] Support Rename, Duplicate and confirmed Delete.
- [ ] Support event editing/deletion/reordering where technically safe.
- [ ] Show playback progress, repeat count and approximate duration where available.
- [ ] Allow immediate cancellation.
- [ ] Support Secret references where appropriate.
- [ ] Provide Running/Completed/Cancelled/Failed feedback.
- [ ] Guarantee cancellation/failure cleans up held input.

## Secrets

Create one shared Secrets system for Shortcuts, Presets and Macros.

Storage contract:

`Secret value → iOS Keychain`

`SwiftData → Secret ID + display metadata/reference only`

Never store plaintext Secret values in SwiftData.

- [ ] Create Secret.
- [ ] Rename Secret metadata.
- [ ] Replace/update Secret value.
- [ ] Delete Secret.
- [ ] Explicitly reveal Secret only on deliberate user action.
- [ ] Allow actions to select/reference a Secret without copying plaintext into their persistent model.
- [ ] Handle deleted/missing/unavailable Keychain references safely and never substitute an empty value silently.
- [ ] Clear temporary Secret UI state after use where practical.
- [ ] Audit logging, diagnostics, errors, model descriptions and crash metadata so Secret values cannot leak.
- [ ] Reduce accidental screenshot/app-switcher exposure where reasonably possible.

Preferred model:

`Shortcut / Preset / Macro → SecretReference("work-password") → Keychain`

## Migration

Preserve existing devices, Shortcuts, Presets, Macros and user configuration where reasonably possible. Define and test explicit SwiftData migration before schema changes. Never use a migration path that temporarily persists plaintext Secrets in SwiftData.

## Exit criteria

Preset and Macro execution states are reliable, cancellation/failure safely releases input, and Secrets can be referenced by supported actions while remaining exclusively Keychain-backed.

---

# 6. Apple Shortcuts / App Intents

## Goal

Make InputPilot automatable from Apple's Shortcuts app and Siri using modern App Intents while reusing the same action, connection and transport architecture as the app itself.

## Architecture

Preferred flow:

`Apple Shortcuts → App Intent → InputPilot service/action → Execution Service → Active Transport → ESP32`

Do not create independent BLE/TCP/REST implementations inside App Intents. Do not use legacy URL schemes as the primary automation architecture.

## Initial intents

Prioritize:

- [ ] Run InputPilot Shortcut.
- [ ] Run Preset.
- [ ] Run Macro.
- [ ] Send Keyboard Shortcut.
- [ ] Send Text.
- [ ] Connect Device.
- [ ] Switch Device.
- [ ] Start Mouse Move.
- [ ] Stop Mouse Move.
- [ ] Check Device Status using high-level product state.

Expose device/action parameters only where useful and avoid leaking protocol internals.

## Secrets

Apple Shortcuts should trigger Secret-backed InputPilot actions without receiving the plaintext Secret.

Preferred flow:

`Apple Automation → Run "Work Login" → InputPilot Shortcut → SecretReference → Keychain → Device`

Do not implement `Get InputPilot Secret Value` or equivalent. Do not return Secret values from App Intents, expose them in parameter suggestions, use them as entity display names or write them into Apple Shortcut configuration.

## Background behavior

Investigate and document what iOS reliably permits while InputPilot is foreground, background, suspended or terminated. Do not promise unsupported execution behavior or add lifecycle hacks solely to bypass iOS restrictions.

When execution cannot proceed because the device/connection/authentication/lifecycle state is unavailable, return a useful actionable result.

## Exit criteria

Core intents execute through shared InputPilot services, foreground behavior is reliable, supported background behavior is documented/tested, unavailable-device cases fail usefully, and Secret-backed actions never expose plaintext Secrets to Apple Shortcuts.

---

# 7. Firmware Compatibility & OTA

## Goal

Keep app and firmware independently versioned while making compatibility, downgrade protection and OTA behavior understandable and safe.

## Existing implementation

The repository already contains firmware compatibility validation, detailed update progress and integrity checking. Build on these rather than replacing working paths without reason.

## Remaining work

- [ ] Audit compatibility metadata/capabilities such as firmware version, protocol version, OTA schema, minimum app/firmware requirements and supported features.
- [ ] Never require `App Version == Firmware Version`.
- [ ] Prevent unsupported firmware downgrade by default.
- [ ] Ensure firmware-side downgrade rejection exists where required; the app alone must not be the security boundary.
- [ ] Do not assume newer firmware is automatically incompatible; use explicit protocol/capability checks.
- [ ] Present a clear newer-firmware/requires-newer-app message when applicable.
- [ ] Clearly show installed → available firmware version and release notes where available.
- [ ] Preserve understandable Downloading/Validating/Transferring/Installing/Rebooting/Reconnecting/Completed progress.
- [ ] Provide dedicated success/failure results and actionable compatibility errors.
- [ ] Keep an explicit developer-only downgrade override only if it remains useful.

## Firmware size

0.9 firmware changes must remain size-conscious. Do not add firmware dependencies merely for app-side visual features. Track meaningful binary-size increases and justify them. Prefer shared BLE/Wi-Fi protocol functionality rather than duplicated implementations.

## Exit criteria

Normal OTA, validation failure, interrupted OTA/recovery, incompatible firmware, downgrade rejection and reconnect-after-update behavior pass the release matrix.

---

# 8. Final Polish & 0.9 Release Gate

## Goal

Finish the product as a coherent 0.9 release rather than treating completion of individual features as release readiness.

## Settings & diagnostics

Keep user-facing settings understandable. A suitable structure may include:

- Connection
- Appearance
- Trackpad
- Keyboard
- Shortcuts
- Secrets
- Advanced
- About

Keep protocol, OTA schema, raw transport state, build/commit information, logs and internal IDs in Advanced/Diagnostics. Consider Developer Mode for especially low-level controls.

## Repository presentation

Once the UI is stable:

- [ ] Add/update current InputPilot logo.
- [ ] Replace outdated screenshots with real current iOS screenshots.
- [ ] Add relevant Android screenshots only where appropriate/current.
- [ ] Update README feature overview.
- [ ] Add/update architecture diagram: `iPhone → BLE / Wi-Fi → ESP32-S3 → USB HID → Computer`.

Recommended screenshots include Devices, Device Details, Trackpad, Keyboard, Shortcuts, Presets, Secrets, Firmware and Settings.

## Testing strategy

Testing is continuous; the release gate is final verification rather than the first testing phase.

### Unit/integration priorities

- action serialization/execution
- Secret references and missing Secrets
- connection-state transitions
- compatibility logic
- Shortcut execution
- Preset execution
- Macro cancellation
- held-input cleanup
- Action → Transport
- Shortcut/Preset/Macro → Action
- Secret → Action
- App Intent → Action

### Physical hardware matrix

- [ ] BLE HID.
- [ ] Wi-Fi HID.
- [ ] BLE-only operation.
- [ ] Wi-Fi-only operation.
- [ ] automatic fallback and active-transport presentation.
- [ ] reconnect behavior.
- [ ] authentication failure/recovery.
- [ ] BLE OTA.
- [ ] OTA rollback/failure recovery.
- [ ] Trackpad on real hardware.
- [ ] keyboard/mouse release after disconnect/failure.

Mocks and simulators do not replace these hardware gates.

### Secrets gate

- [ ] Keychain create/read/update/delete.
- [ ] no plaintext Secret in SwiftData.
- [ ] no Secret values in logs/diagnostics.
- [ ] missing/deleted Secret reference behavior.
- [ ] restart/migration/restore behavior where applicable.

### Apple Shortcuts gate

- [ ] foreground execution.
- [ ] supported background execution.
- [ ] connected and unavailable device behavior.
- [ ] BLE-only and Wi-Fi execution where supported.
- [ ] invalid parameters.
- [ ] Shortcut/Preset/Macro execution.
- [ ] Secret-backed action without Secret exposure.
- [ ] Siri behavior where supported.

### UI/accessibility gate

- [ ] Light Mode reviewed.
- [ ] Dark Mode reviewed.
- [ ] System appearance reviewed.
- [ ] smallest supported iPhone reviewed.
- [ ] largest current iPhone reviewed.
- [ ] Dynamic Type reviewed.
- [ ] VoiceOver reviewed.
- [ ] Reduce Motion reviewed.
- [ ] safe areas and Tab Bar overlap reviewed.
- [ ] major empty/loading/error/disabled states reviewed.

### Data & safety gate

- [ ] no known data-loss bugs.
- [ ] migrations preserve existing supported user data.
- [ ] no known stuck-key bugs.
- [ ] no known stuck-mouse-button bugs.
- [ ] Macro cancellation/failure releases input.
- [ ] Shortcut/Preset failure releases input.

Every failed required gate is fixed before stable release or explicitly recorded as a release blocker. Required gates must not silently disappear from scope.

---

# Tracking

- `ROADMAP.md` → product scope and desired result.
- `IMPLEMENTATION_0.9.md` → feature-oriented implementation architecture, progress and release gates.
- `CHANGELOG.md` → completed user-visible changes under `Unreleased` until release.
- `docs/` → hardware verification and release-gate evidence where useful.

Keep app and firmware independently versioned. Do not promote a build to stable `0.9.0` merely because individual 0.9 features are present; the complete release gate determines stable readiness.

# Scope control

0.9 is already a large milestone. Unrelated features should normally be deferred unless they directly improve native UX, control quality, Shortcuts, Secrets, Apple automation, transport reliability, input safety, firmware compatibility or 1.0 readiness.

# Definition of 0.9 complete

InputPilot 0.9 is complete when:

1. the app feels like a polished native iOS application
2. BLE and Wi-Fi behavior is reliable and understandable
3. transport fallback behaves correctly
4. held input is safely released after failure/disconnect
5. the Trackpad provides a substantially improved native-feeling experience
6. keyboard input is polished and safe
7. InputPilot Shortcuts have been visually and technically redesigned
8. Shortcuts, Presets and Macros share action execution infrastructure where appropriate
9. Secrets are securely stored in iOS Keychain and referenced without plaintext persistence
10. Apple Shortcuts integration works through modern App Intents without exposing Secret values
11. firmware compatibility and OTA behavior are understandable and safe
12. existing supported user data survives required migrations
13. the complete 0.9 release gate passes

After this point, development should shift from 0.9 feature expansion toward the production-readiness and security work required for InputPilot 1.0.

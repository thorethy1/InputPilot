# InputPilot 0.9 Implementation Plan

## Purpose

This document defines the implementation direction for the InputPilot 0.9 generation.

It complements `ROADMAP.md`.

The roadmap defines **what InputPilot 0.9 should become**.

This document defines **how to approach the work without unnecessarily constraining implementation decisions**.

Codex/engineering should inspect the existing architecture before making changes and is explicitly encouraged to improve architecture where this reduces duplication, improves reliability, or makes future development easier.

Do not blindly preserve existing architecture when a small redesign produces a substantially cleaner result.

At the same time, avoid unnecessary rewrites.

---

# Core Principle

InputPilot 0.9 is primarily an application-quality milestone.

The desired transition is:

`functional developer-oriented application`

→

`polished native iOS product`

The existing working transport and firmware functionality should remain stable while the app around it becomes significantly better.

---

# Suggested 0.9 Development Stages

## Stage 1 — Architecture & Current-State Review

Before implementing major UI changes:

1. Inspect the current iOS architecture.
2. Inspect transport handling.
3. Inspect device state management.
4. Inspect keyboard/mouse execution.
5. Inspect existing Shortcuts.
6. Inspect Presets and Macros.
7. Inspect SwiftData models.
8. Inspect firmware compatibility logic.
9. Inspect existing tests.

Identify:

- duplicated action execution
- duplicated transport logic
- inconsistent state models
- UI state leaking into transport logic
- unsafe held-input handling
- obsolete code
- models that will make Secrets difficult
- models that will make App Intents difficult

Do not perform a large rewrite solely for architectural purity.

Refactor where there is a concrete benefit for 0.9.

---

# Stage 2 — Shared Action Architecture

Before significantly expanding Shortcuts, Secrets and App Intents, evaluate whether InputPilot needs a shared action abstraction.

Conceptually:

`InputPilotAction`

could represent operations such as:

- keyboard key
- keyboard shortcut
- text
- secret reference
- mouse action
- delay
- existing supported automation actions

The exact type hierarchy is intentionally not prescribed.

The goal is more important:

> Shortcuts, Presets, Macros and App Intents should not each implement their own independent HID execution stack.

Prefer:

`UI / App Intent`
→ `Action`
→ `Execution Service`
→ `Active Transport`
→ `ESP32`

over:

`Shortcut UI → BLE`

`Preset UI → separate BLE code`

`App Intent → another transport implementation`

Transport selection and HID execution should have clear ownership.

---

# Stage 3 — Input Safety Foundation

Before adding more automation capability, strengthen input safety.

Create a reliable centralized mechanism for releasing held input.

Ensure safe recovery for:

- BLE disconnect
- Wi-Fi disconnect
- transport switch
- timeout
- cancelled Macro
- failed Preset
- failed Shortcut
- app lifecycle interruptions where relevant

Keyboard:

`Release All Keys`

Mouse:

`Release All Buttons`

Where practical, execution systems should use cleanup semantics comparable to:

`begin → execute → success/failure/cancel → guaranteed cleanup`

Avoid situations where every feature has to remember its own cleanup implementation.

Add regression tests.

---

# Stage 4 — Native Design System

Establish the visual foundation before independently redesigning every screen.

Create reusable native styling for:

- typography
- spacing
- cards
- buttons
- status presentation
- destructive actions
- loading
- success
- failure
- empty states

Support:

- Light
- Dark
- System
- Custom Accent

Use semantic colors.

Do not make the configurable InputPilot accent responsible for:

- errors
- destructive actions
- warnings

Prefer SwiftUI system behavior.

Avoid unnecessary custom UI components when iOS already provides a suitable native component.

Support Liquid Glass where appropriate and available.

---

# Stage 5 — Connection State Model

Review the current connection/transport state implementation.

The UI should consume a coherent device-level state rather than independently interpreting BLE and Wi-Fi state on every screen.

Conceptually separate:

### Device state

- connected
- connecting
- offline
- attention required

from:

### Transport state

- BLE available
- BLE connected
- BLE active
- Wi-Fi available
- Wi-Fi connected
- Wi-Fi active
- reconnecting
- failed

Automatic fallback must not incorrectly make the whole device appear disconnected.

The currently active transport should remain identifiable.

Low-level details belong in Diagnostics.

---

# Stage 6 — Control Experience

## Trackpad

Rework gesture handling deliberately rather than stacking additional SwiftUI gestures onto existing gestures.

Model mutually exclusive interaction states where useful:

`idle`
`moving`
`scrolling`
`clicking`
`dragging`
`zooming`

Implement and tune on real hardware.

Prioritize:

1. reliable movement
2. low-speed precision
3. scrolling
4. clicking
5. drag-and-drop
6. secondary click
7. zoom
8. momentum/haptics

Correctness is more important than feature count.

A stuck drag state is worse than temporarily not supporting an advanced gesture.

---

# Stage 7 — Keyboard

Improve:

- modifier handling
- sticky modifiers
- key feedback
- input field behavior
- keyboard dismissal
- safety

Add:

`Release All Keys`

Add explicit clipboard import.

Clipboard content should enter the editable input field before transmission.

Do not automatically transmit clipboard content immediately after reading it.

---

# Stage 8 — InputPilot Shortcuts Redesign

Treat Shortcuts as a first-class feature.

Do not limit the work to visual changes.

Review the current Shortcut data model and execution model.

Shortcuts should become reusable actions that can be:

- created
- renamed
- edited
- duplicated
- deleted
- reordered
- favorited
- executed

The UI should feel native and compact.

Avoid full-width oversized keyboard buttons where they provide no benefit.

Execution must provide:

- immediate feedback
- running state where applicable
- completion
- failure

Shortcuts should integrate with the shared action execution architecture.

---

# Stage 9 — Secrets Architecture

Implement Secrets as a shared system.

## Storage contract

The actual value belongs in:

`iOS Keychain`

Persistent application models contain only:

- ID
- display name
- metadata
- reference

Never the secret value.

SwiftData must not contain plaintext Secrets.

## Consumers

Secrets should be usable by:

- Shortcuts
- Presets
- Macros

Future action consumers should be able to use the same system.

## Lifecycle

Support:

- Create
- Read for execution
- Update
- Delete
- Rename metadata

Consider behavior when:

- a referenced Secret is deleted
- Keychain data is unavailable
- device migration occurs
- app data is restored without matching Keychain entry

Broken references must fail safely.

Never silently substitute an empty value.

## Logging

Audit logging paths.

Secret values must never be included in:

- print()
- Logger
- diagnostics exports
- errors
- model descriptions
- crash metadata

Avoid holding plaintext Secret values longer than necessary.

---

# Stage 10 — Presets & Macros

After the action/Secret architecture is established, migrate or adapt Presets and Macros where beneficial.

Do not rewrite stable behavior unnecessarily.

Presets:

- fix execution
- improve management
- improve visual presentation
- add Secret references
- improve feedback

Macros:

- improve management
- progress
- cancellation
- event editing where safe
- Secret references where appropriate

Cancellation must guarantee held-input cleanup.

---

# Stage 11 — Apple Shortcuts / App Intents

Implement modern App Intents.

Do not use legacy URL schemes as the primary integration architecture.

## Architecture

Preferred:

`Apple Shortcuts`
→ `App Intent`
→ `InputPilot service/action`
→ `Connection/Transport`
→ `ESP32`

App Intents must not contain independent BLE/TCP implementations.

Reuse the application's existing services.

---

# Initial App Intent Set

Prioritize:

### Run Shortcut

Parameters:

- InputPilot device where needed
- InputPilot Shortcut

### Run Preset

Parameters:

- device
- preset

### Run Macro

Parameters:

- device
- macro

### Send Keyboard Shortcut

Parameters:

- device
- keyboard shortcut

### Send Text

Parameters:

- device
- text

### Connect Device

Parameter:

- saved device

### Switch Device

Parameter:

- saved device

### Mouse Move

Actions:

- Start Mouse Move
- Stop Mouse Move

### Device Status

Return useful high-level information.

Avoid exposing internal protocol details unnecessarily.

---

# App Intents + Secrets

Security is important here.

Apple Shortcuts should normally reference an InputPilot action containing a Secret reference.

Example:

`Apple Automation`
→ `Run "Work Login"`
→ `InputPilot`
→ `SecretReference`
→ `Keychain`
→ `ESP32`

The Apple Shortcut therefore does not need to contain:

`actual password`

Do not provide an App Intent such as:

`Get Secret Value`

Do not return Secret values from App Intents.

Do not expose Secret values as entity display names or parameter suggestions.

---

# Background Execution

Investigate what iOS permits for App Intent execution while InputPilot is:

- foreground
- background
- suspended
- terminated

Do not promise behavior that iOS cannot reliably provide.

Where execution requires the application or a connection state that is unavailable, return a useful actionable result.

Avoid hacks designed solely to circumvent iOS lifecycle restrictions.

Document unavoidable platform limitations.

---

# Stage 12 — Firmware Compatibility UX

Keep app and firmware versions independent.

Build compatibility around explicit metadata/capabilities.

Review whether the current firmware already exposes sufficient information.

Potential metadata:

- firmware version
- protocol version
- OTA schema
- minimum app version
- capabilities

Downgrade prevention should exist on the firmware side.

The app alone must not be the security boundary.

Developer builds may optionally support an explicit downgrade override.

---

# Stage 13 — Settings & Diagnostics

Separate product UI from developer information.

Normal settings should focus on things users understand.

Suggested sections:

`Connection`
`Appearance`
`Trackpad`
`Keyboard`
`Shortcuts`
`Secrets`
`Advanced`
`About`

Advanced/Diagnostics may contain:

- protocol
- OTA schema
- transport state
- firmware metadata
- logs
- internal IDs

Consider hiding especially low-level options behind Developer Mode.

---

# Stage 14 — Repository Presentation

Once the 0.9 UI is sufficiently stable:

- capture real screenshots
- update README
- add current logo
- remove obsolete screenshots
- add architecture diagram

Do not capture screenshots early and then redesign the screens afterward.

---

# Testing Strategy

Do not wait until the end of 0.9 to test.

Each stage should add or update tests.

## Unit tests

Prioritize:

- action serialization
- action execution
- Secret references
- missing Secrets
- compatibility logic
- connection state transitions
- Shortcut execution
- Macro cancellation

## Integration tests

Prioritize:

- Action → Transport
- Shortcut → Action
- Preset → Action
- Secret → Action
- App Intent → Action

## Hardware tests

Real ESP32-S3 testing remains required for:

- BLE HID
- Wi-Fi HID
- transport fallback
- reconnect
- OTA
- keyboard release
- mouse release
- Trackpad gestures

Simulators and mocks are not sufficient for the release gate.

---

# Migration & Compatibility

Existing user data should be preserved where reasonably possible.

Before modifying SwiftData schemas:

- inspect existing models
- create appropriate migration strategy
- test upgrade from current released builds

Do not silently delete:

- devices
- presets
- macros
- shortcuts
- user configuration

If an old model cannot represent the new architecture directly, provide an explicit migration.

---

# Performance

0.9 UI polish must not make control input feel slower.

Pay attention to:

- trackpad event frequency
- SwiftUI redraws
- transport queues
- App Intent startup
- macro playback
- excessive state observation

Avoid unnecessary work on the main actor.

Measure before introducing complicated optimizations.

---

# Firmware Size

Firmware changes during 0.9 should remain size-conscious.

Do not add firmware dependencies merely to support an app-side UX improvement.

Track firmware binary size during development.

Any meaningful firmware-size increase should have a clear reason.

Avoid duplicating functionality across BLE and Wi-Fi implementations where a shared implementation is possible.

---

# Scope Control

0.9 is already a large milestone.

Do not opportunistically add unrelated features.

Features that do not directly improve:

- native UX
- control quality
- Shortcuts
- Secrets
- Apple automation
- reliability
- compatibility
- 1.0 readiness

should normally be deferred.

---

# Definition of Done

The 0.9 generation is complete when InputPilot:

1. feels like a polished native iOS application
2. has reliable BLE/Wi-Fi control behavior
3. has a substantially improved Trackpad
4. has a redesigned Keyboard experience
5. has a redesigned first-class Shortcut system
6. stores Secrets securely in Keychain
7. allows Shortcuts/Presets/Macros to reference Secrets
8. integrates with Apple Shortcuts through App Intents
9. safely releases held inputs on failure
10. provides understandable firmware/update UX
11. has consistent loading/error/offline states
12. passes the 0.9 release gate

At that point development should shift away from feature expansion and toward the production-readiness work required for InputPilot 1.0.

# InputPilot Roadmap

## 🎨 0.9.x — Native iOS Experience, Shortcuts & Automation

### Goal

InputPilot should stop feeling like a development utility and start feeling like a polished native iOS application.

The 0.9 generation focuses on:

- Native iOS UX and visual polish
- Reliable control interactions
- A redesigned InputPilot Shortcut system
- Secure reusable Secrets
- Apple Shortcuts / App Intents integration
- Better firmware and transport UX
- Preparing the product for the first stable 1.0 release

Major new transport protocols should generally be avoided during 0.9 unless required for reliability or one of the features below.

---

# 0.9.0 — Native iOS Polish & Control Experience

## 🎨 App Design System

Create one consistent native InputPilot design system.

### Appearance

- Full Light Mode support
- Full Dark Mode support
- System appearance support
- Custom accent color support
- Proper iOS Liquid Glass behavior where supported
- Prefer native SwiftUI components wherever possible

### Design consistency

Define consistent:

- spacing
- corner radii
- typography
- button styles
- cards
- status indicators
- toolbar actions
- destructive actions
- empty states

Introduce semantic colors:

- accent / tint
- success
- warning
- error
- destructive
- connected
- available
- offline

Custom themes may change branding/accent colors but must not redefine destructive or status meaning.

Do not use the brand accent as a destructive color.

Important states must never be communicated by color alone.

### Interaction states

Major controls should consistently support:

- normal
- pressed
- loading
- disabled
- success
- failure

Add:

- appropriate haptic feedback
- clear action feedback
- duplicate-execution protection where required

### Accessibility

Support:

- Dynamic Type
- VoiceOver
- sufficient contrast
- larger interaction targets
- Reduce Motion

### Design inspiration

Termius for iOS.

Focus on:

- gestures
- restrained UI
- native navigation
- contextual actions
- clean status presentation
- minimal permanent controls

Do not copy Termius visually.

---

## 🔗 Connection & Transport UX

A normal user should immediately understand whether InputPilot is usable without understanding the transport architecture.

Clearly distinguish:

- available
- connected
- active
- reconnecting
- unavailable
- failed

Always make the currently active control transport identifiable.

Automatic BLE/Wi-Fi fallback should be understandable and must not appear as a complete connection failure when another transport is still operational.

Normal UI should primarily expose high-level states:

- Connected
- Connecting
- Offline
- Attention Required

Detailed BLE / Wi-Fi TCP / REST information belongs in Advanced / Diagnostics.

Connection state must remain consistent across:

- Devices
- Device Details
- Control
- Settings

Connection errors should provide useful recovery actions:

- Retry
- Open Settings
- Switch transport
- Short human-readable reason

Unexpected disconnects must safely release held keyboard keys and mouse buttons.

---

## 📱 Device & Multi-Device UX

- Clearly indicate the active device
- Replace ambiguous device switches with native selection patterns
- Remember the last active device where appropriate
- Make switching between saved devices fast
- Use native swipe/context actions
- Distinguish:
  - saved
  - nearby
  - connected
  - offline
- Show transport availability without making the device list overly technical
- Make destructive actions visually and behaviorally distinct

---

## 🎮 Control Tab Redesign

The Control tab should become one of the strongest parts of InputPilot.

### Trackpad

Make the trackpad behave as closely as possible to a real laptop trackpad.

Improve:

- pointer smoothing
- acceleration curve
- low-speed precision
- two-finger scrolling
- momentum / inertial scrolling
- tap to click
- double tap / double click
- press / hold for right click
- two-finger secondary click where appropriate
- drag and drop
- reliable drag release
- pinch-to-zoom
- configurable sensitivity
- natural scrolling as the fixed default (the toggle was intentionally removed for a gesture-first trackpad)

Add subtle haptic feedback where appropriate.

Provide lightweight first-use gesture hints without permanently cluttering the trackpad.

Explicit left/middle/right controls have been removed now that every action is gesture-reachable (taps, holds and multi-finger taps cover left/right/middle); they may return as an accessibility fallback if hardware testing shows gaps.

### Gesture architecture

Gestures must not conflict.

Use an explicit state model similar to:

`idle → moving → scrolling → clicking → dragging → zooming`

Unexpected disconnects must always release held mouse buttons.

---

## ⌨️ Keyboard Improvements

- Improve keyboard layout
- Improve modifier-key presentation
- Support clear sticky/latched modifier behavior where useful
- Add explicit `Release All Keys`
- Ensure held keys are released after disconnect/error paths
- Better visual feedback when input is sent
- Better keyboard dismissal behavior
- Improve text input field

### Paste Clipboard

Add a dedicated Paste Clipboard action.

- Read clipboard only after explicit user interaction
- Paste into the editable text field first
- User can review/edit before sending
- Show feedback for empty/unavailable clipboard
- Preserve field-clearing behavior after successful send
- Never unnecessarily persist clipboard contents
- Never log clipboard contents

Possible send animation:

`typed text → send animation → device → field clears`

---

# 0.9.1 — InputPilot Shortcuts & Secure Secrets

## ⚡ InputPilot Shortcut System

The existing Shortcut feature should receive both a visual and architectural redesign.

Shortcuts should become reusable first-class InputPilot actions rather than simple UI buttons around hard-coded key combinations.

### Visual redesign

- Native SwiftUI presentation
- Compact shortcut controls
- Avoid excessively stretched buttons
- Consistent icons
- Better modifier presentation
- Categories where useful
- Favorites
- Reordering
- Context menus / swipe actions where appropriate

Support:

- Rename
- Duplicate
- Delete
- Reorder
- Favorite / unfavorite

Execution states:

- Ready
- Running
- Completed
- Failed

Add optional haptic feedback.

### Shortcut capabilities

Shortcuts should be able to represent reusable actions such as:

- key
- key combination
- modifier sequence
- text
- secret
- potentially other reusable InputPilot actions where architecture allows

Avoid building a separate execution implementation for every feature.

Create or evolve toward a shared action model that can be reused by:

- Shortcuts
- Presets
- Macros
- Apple App Intents

Example:

`InputPilotAction`

with actions such as:

- `key(...)`
- `shortcut(...)`
- `text(...)`
- `secretReference(...)`
- `mouse(...)`
- `delay(...)`

Exact implementation is left to engineering review.

### Safety

- Never leave modifier keys held after failure
- Always release held keys after unexpected disconnect
- Provide `Release All Keys`
- Prevent accidental duplicate execution where appropriate
- Clearly communicate execution failure

---

## 🔐 Unified Secrets System

Create one shared Secrets architecture for InputPilot.

Secrets may contain:

- passwords
- tokens
- sensitive text
- other credentials

Secrets should be reusable from:

- InputPilot Shortcuts
- Presets
- Macros

Architecture:

`Shortcut / Preset / Macro → SecretReference → iOS Keychain`

### Storage

Secret values must never be stored as plaintext in SwiftData.

Use:

- iOS Keychain → actual secret value
- SwiftData → metadata/reference ID only

Example:

`SecretReference("work-password")`

instead of embedding:

`"SuperSecretPassword123"`

### Secret management

Provide a native UI to:

- Create Secret
- Rename Secret
- Replace value
- Delete Secret
- Explicitly reveal Secret where appropriate
- Select Secret when building an action

### Security requirements

Secret values must never appear in:

- normal logs
- diagnostics
- crash reports
- debug descriptions
- serialized preset/macro/shortcut models

Avoid exposing Secrets in:

- screenshots
- app switcher snapshots

where reasonably preventable.

Clear temporary secret UI state after use.

Do not unnecessarily copy secret values into long-lived application state.

Deleting a Secret that is referenced by an action must be handled safely.

The UI should identify broken references without revealing the old Secret value.

---

## ⚡ Presets Improvements

Presets should use the shared InputPilot action architecture where practical.

- Fix broken Run button
- Better cards/rows
- Rename
- Duplicate
- Edit
- Delete
- Swipe actions
- Drag-and-drop ordering
- Better favorites
- Secret references
- Clear execution feedback

States:

- Run
- Running
- Completed
- Failed

Prevent duplicate execution while already running where appropriate.

---

## ⏺️ Macro Improvements

- Better list/card presentation
- Rename
- Duplicate
- Delete with confirmation
- Edit/delete individual events where technically safe
- Reorder events
- Playback progress
- Repeat count
- Approximate duration
- Cancel immediately
- Support Secret references where technically appropriate

States:

- Running
- Completed
- Cancelled
- Failed

Cancellation or failure must release all held keyboard keys and mouse buttons.

---

# 0.9.2 — Apple Shortcuts & App Intents

## 🍎 Apple Shortcuts Integration

InputPilot should integrate with the native iOS Shortcuts application using modern App Intents.

Do not create a second independent automation engine.

Apple App Intents should call into the same underlying InputPilot services/action execution architecture used by the app.

### Initial App Intents

Evaluate and implement:

- Run InputPilot Shortcut
- Run Preset
- Run Macro
- Send Keyboard Shortcut
- Send Text
- Connect Device
- Switch Device
- Start Mouse Move
- Stop Mouse Move
- Check Device Status

Additional actions may be added where they provide clear value.

### Example automations

`When Work Focus starts → Connect InputPilot → Run Work Setup`

`When joining work Wi-Fi → Connect InputPilot`

`Siri → Run InputPilot Presentation Shortcut`

`Personal Automation → Run InputPilot Macro`

### App Intent requirements

Actions should:

- expose useful parameters
- return meaningful success/failure results
- work predictably when InputPilot is not currently open where iOS permits
- select saved InputPilot devices where appropriate
- handle offline devices gracefully
- reuse existing connection logic
- reuse existing execution logic

Do not duplicate BLE/Wi-Fi transport implementations inside App Intents.

### Security & Secrets

Apple Shortcuts must never receive the plaintext value of an InputPilot Secret unless explicitly required by a future carefully reviewed design.

Preferred architecture:

`Apple Shortcut → App Intent → InputPilot Shortcut/Preset → SecretReference → Keychain → Device`

rather than:

`Apple Shortcut → plaintext password → InputPilot`

This allows an iOS automation to trigger an authenticated InputPilot action without exposing the credential inside the user's Apple Shortcut workflow.

Secret values should not be returned as App Intent results.

### Siri

Where supported naturally through App Intents, allow commands such as:

- Run an InputPilot Shortcut
- Run a Preset
- Connect InputPilot

Avoid maintaining a separate legacy Siri integration.

---

# 0.9.x — Firmware Compatibility & Update UX

App and firmware releases remain independently versioned.

Do not require:

`firmware version == app version`

Use explicit compatibility metadata such as:

- firmware version
- protocol version
- OTA schema
- minimum supported app version
- minimum supported firmware version
- supported capabilities

### Update behavior

- Prevent firmware downgrade by default
- Firmware must reject unsupported downgrade attempts
- Detect firmware newer than the installed app understands
- Never automatically downgrade because the app is older
- Continue capability-based compatibility checks
- Never assume newer firmware automatically means incompatible

Example message:

> This firmware requires a newer version of InputPilot.

### Firmware update UX

- Check for latest compatible firmware
- Show installed → available version
- Show release notes before update
- Validate firmware integrity
- Clear OTA stages:
  - Downloading
  - Validating
  - Transferring
  - Installing
  - Rebooting
  - Reconnecting
  - Completed
- Dedicated success/failure result
- Human-readable compatibility errors

Optional developer feature:

- Manual downgrade override for development builds

---

# ⚙️ Settings, Advanced & Developer Information

Separate normal user settings from technical diagnostics.

Suggested structure:

- Connection
- Appearance
- Trackpad
- Keyboard
- Shortcuts
- Secrets
- Advanced
- About

Move low-level information into Advanced / Diagnostics:

- protocol version
- OTA schema
- commit information
- transport diagnostics
- logs
- internal IDs

Consider Developer Mode for additional technical controls.

Use native SwiftUI `Form` / `Section` patterns consistently.

---

# 🧩 Empty, Loading & Error States

Add polished states for:

- no devices
- searching
- device offline
- Bluetooth disabled
- Bluetooth permission missing
- Local Network permission missing
- no shortcuts
- no presets
- no macros
- missing Secret reference
- firmware unavailable
- connection lost
- update failed

Prefer native:

- `ContentUnavailableView`
- `ProgressView`

Every recoverable error should provide an obvious recovery action.

Avoid permanent unexplained spinners.

---

# 📐 Adaptive Layout & Safe Areas

- No controls overlapping Tab Bar/system safe areas
- Test smallest supported iPhone
- Test largest current iPhone
- Dynamic Type
- Landscape where useful
- Prepare cleanly for future iPad support
- Avoid brittle fixed sizes

---

# 📸 Repository Presentation

- Add current InputPilot logo
- Replace outdated screenshots
- Add real iOS screenshots
- Add Android screenshots where appropriate
- Add architecture diagram
- Add concise feature overview

Recommended screenshots:

1. Devices
2. Device Details
3. Trackpad
4. Keyboard
5. Shortcuts
6. Presets
7. Secrets
8. Firmware Update
9. Settings

Architecture:

`iPhone → BLE / Wi-Fi → ESP32-S3 → USB HID → Computer`

---

# 🧪 0.9 Release Gate

0.9 should not be considered complete until:

### Transport / hardware

- automated tests pass
- BLE HID hardware test passes
- Wi-Fi HID hardware test passes
- BLE OTA hardware test passes
- OTA recovery tested
- connection fallback tested
- active transport presentation tested

### Input safety

- no known stuck-key bugs
- no known stuck-mouse-button bugs
- disconnect releases held input
- macro cancellation releases held input
- shortcut failures release held input

### Shortcuts

- Shortcut CRUD tested
- Shortcut ordering tested
- Shortcut execution tested
- Shortcut Secret references tested
- missing Secret handling tested

### Secrets

- no plaintext Secrets in SwiftData
- no Secrets in logs
- no Secrets in diagnostics
- Keychain create/read/update/delete tested
- referenced Secret deletion tested
- app relaunch tested
- device migration/Keychain behavior reviewed

### Apple Shortcuts

Test App Intents with:

- app foreground
- app background where supported
- connected device
- disconnected device
- BLE-only device
- Wi-Fi-connected device
- unavailable device
- invalid parameters
- referenced Shortcut
- referenced Preset
- referenced Secret
- Siri invocation where supported

### Clipboard

Test:

- normal text
- empty clipboard
- multiline text
- special characters
- large contents
- unavailable access

### UI

- Light Mode reviewed
- Dark Mode reviewed
- smallest supported iPhone reviewed
- largest current iPhone reviewed
- Dynamic Type reviewed
- safe areas reviewed
- loading/error/disabled states reviewed
- no known data-loss bugs

---

# 🚀 1.0.0 — First Stable Release

## Goal

InputPilot should be ready to install and use by somebody who has never seen the project before.

1.0 should primarily be a production-readiness release rather than another large feature release.

---

## 👋 First-Run Setup

Create a dedicated native onboarding experience.

Flow:

`Welcome → Hardware → USB → Device Discovery → Bluetooth → Pair → Optional Wi-Fi → Authentication → Connection Test → Mouse Test → Keyboard Test → Complete`

The user should not need to understand:

- BLE characteristics
- TCP ports
- REST endpoints
- ESP32 internals

Permission requests should explain why access is needed.

BLE-only setup must remain fully supported.

---

## 🔒 Security Hardening

Secure by default.

- Authentication enabled by default
- No secret/token logging
- Secrets only in Keychain
- Secure credential provisioning
- Rate limiting where appropriate
- Review replay resistance
- Review session authentication
- Review BLE pairing/security
- Review Wi-Fi transport security

Policy:

> User input must not be transmitted over an unauthenticated plaintext control channel by default.

Evaluate encryption independently for:

- BLE
- TCP
- REST

Authentication must not be described as encryption.

---

## ✍️ Signed Firmware Updates

SHA-256 verifies integrity but not authenticity.

Evaluate cryptographically signed official firmware.

Target:

`Release Signing Key → Firmware Signature → InputPilot Verification`

- Sign official firmware
- Verify before OTA activation
- Reject modified/untrusted firmware
- Keep private signing keys outside repository

Evaluate ESP32 Secure Boot separately before enabling irreversible eFuse protections.

---

## 📦 Repository Cleanup

- Rewrite README around InputPilot
- Remove obsolete terminology
- Remove obsolete helper references
- Remove dead code
- Remove unused assets
- Remove obsolete documentation
- Review repository structure
- Review LICENSE
- Review SECURITY.md
- Review CONTRIBUTING.md
- Finalize CHANGELOG

Preserve Git history and upstream attribution.

---

## 🧹 1.0 Quality Gate

Before `v1.0.0`:

- zero known critical bugs
- zero known stuck-input bugs
- OTA recovery tested
- interrupted OTA tested
- wrong firmware rejection tested
- downgrade rejection tested
- old-app/new-firmware tested
- new-app/old-firmware tested
- BLE-only setup tested
- Wi-Fi setup tested
- offline behavior tested
- authentication failures tested
- fresh ESP32 install tested
- fresh iOS install tested
- onboarding tested
- README installation followed from scratch
- release artifacts tested
- screenshots current

---

# 🔮 1.x — Computer Integration

## Computer → InputPilot Communication

Add bidirectional computer communication.

Possible architecture:

`Computer ⇄ USB Vendor HID ⇄ ESP32 ⇄ BLE/Wi-Fi ⇄ InputPilot`

Potential features:

- active application
- PC lock/unlock state
- volume
- media state
- Num Lock
- Caps Lock
- custom computer events
- application-specific controls
- computer → iPhone status feedback

Keep normal keyboard/mouse HID independent from the InputPilot vendor communication interface.

---

# 💡 Future Ideas

Potential post-1.x features:

- Per-app computer profiles
- Dynamic controls based on active desktop application
- Advanced clipboard integration
- Media controls
- Custom gesture actions
- iPad optimized layout
- Landscape trackpad mode
- External keyboard support
- Apple Watch companion
- Widgets
- Control Center controls
- Import/export presets
- Encrypted preset backup
- Multiple InputPilot device groups

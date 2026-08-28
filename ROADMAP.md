InputPilot Roadmap

✅ 0.8.x — Firmware, OTA & Reliability Foundation

Goal: Build a reliable technical foundation before focusing on UX and the first stable release.

Completed

* BLE firmware OTA
* Wi-Fi / firmware update infrastructure
* Dual-slot OTA firmware layout
* Firmware compatibility validation
* Firmware diagnostics
* Transport diagnostics
* BLE / HID reliability improvements
* E2E test infrastructure
* Native iOS tab navigation
* BLE as first-class InputPilot transport
* Release artifacts and firmware manifests

Completed in 0.8.3

* Replaced the incorrect capability-derived “Bluetooth Available” status with live Bluetooth radio, discovery, connection, authentication, and readiness state.
* Saved devices now begin in a checking state and clearly become ready, online via Wi-Fi, reconnecting, authentication failed, setup required, or offline from live transport information.
- [x] Improve Connection UX & Transport State
  - Clearly distinguish Available / Connected / Active / Reconnecting
  - Always show which transport is currently used
  - Make Automatic transport fallback understandable
  - Do not show "Reconnecting" when another transport is actively working
  - Add clear connection error states and recovery actions
  - Transport state must stay consistent across Device, Control and Settings
* Removed the pointer-jiggle switch from device rows; reworked it as the explanatory “Keep Awake” device-management setting and disabled it without the Wi-Fi connection its API requires.
* Removed ambiguous “Ready to Move” and “Moving” terminology from iOS and Android, plus generic OTA “Available” terminology from the iOS firmware UI.
* Firmware management now distinguishes installed/latest firmware, update available, up to date, installed newer, incompatible firmware, app update required, and unavailable release information.
* Fixed stale Bluetooth connection attempts and prevented ordinary disconnects from creating false OTA failures.

⸻

🎨 0.9.0 — Native iOS Polish & Control Experience

Goal: InputPilot should stop feeling like a development utility and start feeling like a polished native iOS application.

The focus of 0.9 should be UX, interaction quality, consistency and reliability, not major new protocol features.

App Design System

* Full Light Mode support
* Full Dark Mode support
* System appearance support
* Custom accent color support
* Create one consistent InputPilot design system:
    * spacing
    * corner radii
    * typography
    * button styles
    * cards
    * status indicators
    * toolbar actions
    * destructive actions
    * empty states
* Introduce semantic colors instead of reusing the accent color for every state:
    * accent / tint
    * success
    * warning
    * error
    * destructive
    * connected / available / offline
* Custom themes may change branding/accent colors, but must not redefine destructive or status meaning
* Do not use the brand accent as a destructive color
* Important states must never be communicated by color alone
* Define consistent interaction states for major controls:
    * normal
    * pressed
    * loading
    * disabled
    * success
    * failure
* Prefer native SwiftUI components wherever possible
* Proper iOS Liquid Glass behavior where supported
* Remove UI that looks like custom web/mobile controls when a native iOS equivalent exists
* Add appropriate haptic feedback
* Add clear visual feedback when remote actions are sent or fail
* Prevent accidental duplicate execution while an asynchronous command is still running where appropriate
* Improve accessibility
    * Dynamic Type
    * VoiceOver labels
    * sufficient contrast
    * larger interaction targets
    * Reduce Motion support

Design inspiration

Termius for iOS

Focus on:

* gestures
* restrained UI
* native navigation
* contextual actions
* clean status presentation
* minimal permanent controls

Do not copy Termius visually; use it as interaction inspiration.

⸻

🔗 Connection & Transport UX

Goal: A normal user should immediately understand whether InputPilot is usable without needing to understand the transport architecture.

* Clearly distinguish transport states:
    * available
    * connected
    * active
    * reconnecting
    * unavailable
    * failed
* Always make it possible to identify the currently active control transport
* Automatic transport fallback must be understandable and should not look like a total connection failure
* Do not show a generic “Reconnecting” state when another transport is already working normally
* Use a high-level device state such as Connected / Connecting / Offline / Attention Required in normal UI
* Keep detailed BLE / Wi-Fi TCP / REST diagnostics available in Advanced/Diagnostics UI
* Connection state must remain consistent across Devices, Device Details, Control and Settings
* Connection errors must be actionable:
    * retry
    * open relevant permission settings where appropriate
    * switch transport where appropriate
    * show a short reason instead of only an error code
* Unexpected disconnects must safely release held keyboard keys and mouse buttons

⸻

📱 Device & Multi-Device UX

* Clearly indicate the currently active device
* Replace ambiguous device switches with a native selection/connection pattern
* Remember the last active device where appropriate
* Make switching between saved devices fast and obvious
* Use native swipe/context actions for common device management actions
* Clearly distinguish saved, nearby, connected and offline devices
* Show transport availability without making the normal device list overly technical
* Destructive device actions must be visually and behaviorally distinct from normal actions

⸻

🎮 Control Tab Redesign

The Control tab should become one of the strongest parts of InputPilot.

Trackpad

Goal: Make the trackpad behave as closely as possible to a real laptop trackpad.

* Improve pointer movement smoothing
* Improve acceleration curve
* Improve low-speed precision
* Smooth two-finger scrolling
* Momentum / inertial scrolling
* Tap to click
* Double tap / double click
* Press / hold for right click
* Two-finger secondary click if appropriate
* Drag and drop gesture
* Reliable drag release
* Pinch-to-zoom
* Configurable sensitivity
* Natural scrolling option
* Add subtle haptic feedback for click interactions where appropriate
* Add lightweight first-use gesture hints without permanently cluttering the trackpad
* Keep explicit left/middle/right click controls available as a reliable fallback if they remain useful

Gesture architecture

Gestures should not conflict with each other.

Define explicit gesture states such as:

idle → moving → scrolling → clicking → dragging → zooming

Unexpected disconnects must always safely release held mouse buttons.

⸻

⌨️ Keyboard Improvements

* Redesign shortcut buttons
* Avoid excessively stretched full-width buttons
* Use compact native button/grid layouts
* Improve modifier-key presentation
* Support clear sticky/latched modifier behavior where useful
* Add an explicit “Release All Keys” safety action
* Ensure modifiers and held keys are always released after disconnect/error paths
* Better visual feedback when a key/shortcut is sent
* Allow favorite/common shortcuts to be reordered where useful
* Better keyboard dismissal behavior
* Improve text input field
* Add a Paste Clipboard button
    * Paste the current iOS clipboard contents into the text input field
    * Request clipboard access only when the user taps the button
    * Show clear feedback when the clipboard is empty or unavailable
    * Allow the user to review and edit the pasted text before sending
    * Preserve the existing behavior of clearing the field after the text is sent
    * Never log or persist pasted clipboard contents unnecessarily

The text input should still become blank after sending, but sending should feel intentional.

Possible animation:

typed text → send animation → fades/slides toward device → field clears

* Show short success/failure feedback if sending fails

⸻

⚡ Presets Improvements

* Fix broken Run button
* Make preset actions visually consistent
* Better preset cards/rows
* Rename presets
* Duplicate presets
* Swipe actions for edit/delete
* Drag-and-drop ordering
* Better favorite handling
* Clear Run / Running / Completed / Failed execution feedback
* Prevent duplicate execution while a preset is already being sent where appropriate
* Optional haptic feedback when executed

⸻

⏺️ Macro Improvements

* Improve recorded macro list/card presentation
* Rename macros
* Duplicate macros
* Delete macros with an appropriate confirmation flow
* Edit/delete individual macro events where technically safe
* Reorder macro events
* Show playback progress
* Show repeat count and approximate duration where available
* Allow a running macro to be cancelled immediately
* Cancelling or failing a macro must safely release held keys and mouse buttons
* Show clear Running / Completed / Cancelled / Failed states

⸻

🔐 Secrets

Add a dedicated secret type for passwords, tokens and other sensitive text.

* Secrets can be referenced by presets/macros
* Secrets must never be stored as plaintext in SwiftData
* Store secret values in the iOS Keychain
* SwiftData stores only secret metadata/reference IDs
* Require explicit reveal action
* Never include secret values in logs
* Never include secret values in diagnostics
* Never include secret values in crash reports
* Never expose secrets accidentally in UI screenshots/app switcher where reasonably preventable
* Clear secrets from temporary UI state after use

Example:

Preset → SecretReference("work-password") → Keychain

instead of:

Preset → "SuperSecretPassword123"

⸻

🔄 Firmware Compatibility & Update UX

Do not directly require:

Firmware version == App version

App and firmware releases should remain independently versioned.

Instead define explicit compatibility metadata.

Example:

* firmware version
* protocol version
* OTA schema
* minimum supported app version
* minimum supported firmware version
* supported feature capabilities

Update behavior

* Prevent firmware downgrade by default
* Firmware must reject unsupported downgrade attempts, not only the app
* Detect firmware newer than the installed app understands
* Show:

This firmware requires a newer version of InputPilot.

instead of automatically attempting to downgrade it.

* Add minimum_app_version to firmware release metadata if useful
* Continue capability-based compatibility checks
* Never assume that newer firmware automatically means incompatible firmware

Firmware update presentation

* Automatically check for the latest compatible firmware release where appropriate
* Clearly show installed version → available version
* Show release notes/changelog before updating
* Provide clear progress states for:
    * downloading
    * validating
    * transferring
    * installing
    * rebooting
    * reconnecting
    * completed
* Validate firmware integrity/checksum before installation
* Show a dedicated success/failure result instead of silently returning to the previous screen
* Make compatibility errors understandable without exposing raw protocol details unless requested
* Avoid vague labels such as “Available” when a more precise state can be shown

Optional developer-only feature:

* Explicit manual downgrade override for development builds

⸻

⚙️ Settings, Advanced & Developer Information

Goal: Keep normal settings understandable while preserving the strong diagnostics needed during development.

* Separate user-facing settings from technical diagnostics
* Suggested top-level structure:
    * Connection
    * Appearance
    * Trackpad
    * Keyboard
    * Advanced
    * About
* Move protocol version, OTA schema, commit information, raw transport diagnostics and logs into Advanced/Diagnostics
* Keep firmware management discoverable without exposing unrelated implementation details
* Consider a Developer Mode for additional low-level information and debugging controls
* Normal users should not need to understand protocol versions, endpoint details or internal device IDs to operate InputPilot
* Use native SwiftUI Form/Section patterns consistently

⸻

🧩 Empty, Loading & Error States

* Add polished states for:
    * no devices
    * searching for devices
    * device offline
    * Bluetooth disabled
    * Bluetooth permission missing
    * Local Network permission missing
    * no presets
    * no macros
    * firmware unavailable
    * connection lost
    * update failed
* Prefer native ContentUnavailableView and ProgressView patterns where appropriate
* Every recoverable error should provide an obvious recovery action
* Avoid permanent spinners without explanation
* Loading, disabled and error behavior should be consistent across the app

⸻

📐 Adaptive Layout & Safe Areas

* No interactive content may overlap the Tab Bar or system safe areas
* Test the smallest supported iPhone layout
* Test the largest current iPhone layout
* Support Dynamic Type without breaking control layouts
* Support landscape where it materially improves controls such as the trackpad
* Prepare layouts to adapt cleanly to iPad even if full iPad optimization is deferred
* Avoid fixed sizes that cause shortcut labels or controls to wrap into unusable shapes

⸻

📸 Repository Presentation

* Add current InputPilot logo
* Replace outdated screenshots
* Add real iOS screenshots
* Add real Android screenshots where appropriate

Recommended screenshots:

1. Devices
2. Device details
3. Trackpad
4. Keyboard
5. Presets
6. Firmware update
7. Settings

* Add short architecture diagram

Example:

iPhone → BLE / Wi-Fi → ESP32-S3 → USB HID → Computer

* Add a short feature overview near the top of README

⸻

🧪 0.9 Release Gate

0.9.0 should not ship until:

* all automated tests pass
* BLE HID hardware test passes
* Wi-Fi HID hardware test passes
* BLE OTA hardware test passes
* firmware rollback/failure recovery is tested
* Trackpad tested on real hardware
* Connection fallback and active-transport presentation are tested
* Device offline/reconnect UI is tested
* Macro cancellation/failure safely releases all held inputs
* Paste Clipboard button tested with:
    * non-empty text
    * empty clipboard
    * multiline text
    * special characters
    * large clipboard contents
    * denied or unavailable clipboard access
* no known data-loss bugs
* no known stuck-key/stuck-mouse-button bugs
* Light Mode reviewed
* Dark Mode reviewed
* smallest supported iPhone layout reviewed
* largest current iPhone layout reviewed
* no major control overlaps the Tab Bar or safe areas
* empty/loading/error states reviewed for all major screens
* all major controls have loading/error/disabled states

⸻

🚀 1.0.0 — First Stable Release

Goal: InputPilot is ready to be installed and used by somebody who has never seen the project before.

1.0 should mainly be a production-readiness release, not another large feature release.

⸻

👋 First-Run Setup

Create a dedicated native onboarding/setup experience.

Welcome

Explain briefly:

InputPilot turns an ESP32-S3 into a wireless controller for your computer.

Show architecture:

iPhone → ESP32-S3 → USB → Computer

Setup flow

* Welcome
* Required hardware
* Connect ESP32 via USB
* Detect nearby InputPilot device
* Bluetooth permission
* Pair/connect
* Optional Wi-Fi setup
* Device authentication setup
* Connection test
* Mouse movement test
* Keyboard test
* Setup complete

The user should not need to understand BLE characteristics, TCP ports, REST endpoints or ESP32 terminology.

* Permission requests should explain why access is needed before triggering the system dialog
* Discovery and connection failures should offer simple retry/recovery guidance
* Denied Bluetooth/Local Network permissions should provide a clear path to the relevant system settings
* The setup flow should remain usable when optional Wi-Fi setup is skipped

⸻

🔒 1.0 Security Hardening

Goal: Secure by default.

* Authentication enabled by default
* No secret/token logging
* Secrets stored only in Keychain
* Secure credential provisioning
* Rate limiting where appropriate
* Review replay resistance
* Review session authentication
* Review BLE security/pairing configuration
* Review Wi-Fi transport security

Transport security

Define a concrete policy:

User input must not be transmitted over an unauthenticated plaintext control channel by default.

Evaluate encryption separately for:

* BLE
* TCP
* REST

Do not describe authentication as encryption.

⸻

✍️ Signed Firmware Updates

SHA-256 provides integrity checking but does not prove that firmware was created by InputPilot.

Before or around 1.0 evaluate cryptographically signed firmware releases.

Target design:

Release signing key → firmware signature → InputPilot verifies trusted signature

* Sign official firmware
* Verify signature before OTA activation
* Reject modified/untrusted firmware in normal release builds
* Keep private signing keys outside the repository

Evaluate ESP32 Secure Boot separately before enabling irreversible eFuse-based protections.

⸻

📦 1.0 Repository Cleanup

* Rewrite README around the actual InputPilot product
* Remove obsolete terminology
* Remove obsolete hid-helper references where compatibility does not require them
* Remove obsolete InputPilot references from product-facing documentation
* Clean comments and dead code
* Remove unused assets
* Remove obsolete documentation
* Review repository structure
* Review LICENSE
* Review SECURITY.md
* Review CONTRIBUTING.md
* Finalize CHANGELOG

Preserve Git history

Do not rewrite the repository history into a new “InputPilot initial commit”.

Keep the existing history and upstream attribution.

Instead:

* make v1.0.0 the clean product milestone
* remove obsolete product references from current files
* retain required upstream attribution and license history
* optionally document the project’s origin once in an appropriate attribution section

⸻

🧹 1.0 Quality Gate

Before tagging v1.0.0:

* zero known critical bugs
* zero known stuck-input bugs
* OTA recovery tested
* interrupted OTA tested
* wrong firmware rejection tested
* firmware downgrade rejection tested
* old-app/new-firmware behavior tested
* new-app/old-firmware behavior tested
* BLE-only setup tested
* Wi-Fi setup tested
* device offline behavior tested
* authentication failures tested
* fresh ESP32 first-install tested
* fresh iOS install/onboarding tested
* README setup followed successfully from scratch
* release artifacts tested
* real screenshots updated

⸻

🔮 1.x — Computer Integration

After 1.0, InputPilot can expand beyond phone → computer input.

Computer → InputPilot Communication

Add a bidirectional computer communication channel.

Possible architecture:

Computer ⇄ USB Vendor HID ⇄ ESP32 ⇄ BLE/Wi-Fi ⇄ InputPilot

Potential features:

* active application information
* PC lock/unlock state
* volume
* media state
* Num Lock / Caps Lock state
* custom computer events
* application-specific controls
* computer → iPhone status feedback

Keep normal keyboard/mouse HID independent from the InputPilot vendor communication interface.

⸻

⚡ Apple Shortcuts / App Intents

Add native iOS Shortcuts integration.

Possible actions:

* Run Preset
* Run Macro
* Send Shortcut
* Send Text
* Connect Device
* Wake Device
* Switch Device
* Start/Stop Mouse Move
* Check Device Status

Use modern App Intents rather than custom URL schemes wherever possible.

Example automations:

When I connect to my work Wi-Fi → connect InputPilot.

When Focus “Work” starts → run Work Setup preset.

Siri, run my InputPilot presentation preset.

⸻

💡 Future Ideas

Potential features after 1.x:

* Per-app computer profiles
* Dynamic controls based on currently active desktop application
* Clipboard integration
* Media controls
* Custom gesture actions
* iPad optimized layout
* Landscape trackpad mode
* External keyboard support
* Apple Watch companion
* Widgets / Control Center controls
* Import/export presets
* Encrypted preset backup
* Multiple InputPilot device groups

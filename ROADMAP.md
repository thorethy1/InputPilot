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

Remaining 0.8.x Bugs / Reliability Fixes

These should preferably be fixed before beginning major 0.9 UI work.

* Fix incorrect “Bluetooth Available” status
    * Clearly distinguish:
        * Bluetooth supported
        * Bluetooth enabled
        * Device discovered
        * Device connected
        * Device authenticated
        * Device ready
* Device UI must clearly show when a saved device is currently unavailable/offline
* Fix or remove non-functional switch in Devices
* Rework/remove Move feature
    * Current location/function is unclear
    * Move it into an appropriate device-management menu if still necessary
* Replace ambiguous statuses such as:
    * Ready to Move
    * Available in OTA
* OTA UI should clearly distinguish:
    * Installed firmware
    * Latest available firmware
    * Update available
    * Device is up to date
    * Firmware not compatible
    * App update required

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
* Prefer native SwiftUI components wherever possible
* Proper iOS Liquid Glass behavior where supported
* Remove UI that looks like custom web/mobile controls when a native iOS equivalent exists
* Add appropriate haptic feedback
* Improve accessibility
    * Dynamic Type
    * VoiceOver labels
    * sufficient contrast
    * larger interaction targets

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
* Better visual feedback when a key/shortcut is sent
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
* Swipe actions for edit/delete
* Drag-and-drop ordering
* Better favorite handling
* Clear execution feedback
* Optional haptic feedback when executed

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

Optional developer-only feature:

* Explicit manual downgrade override for development builds

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

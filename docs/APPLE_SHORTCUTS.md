# Apple Shortcuts & App Intents

InputPilot ships in-process App Intents so presets, connections and keyboard
actions can be automated from the Shortcuts app and Siri. All intents reuse the
app's own services (`AppIntentSupport` → `ActionExecutor` → `HIDConnectionManager`
→ BLE/Wi-Fi transports). There is no second transport implementation and no URL
scheme.

## Available intents

| Intent | Parameter | Behaviour |
| --- | --- | --- |
| Run Preset | Preset (required), Device (optional, defaults to the active device) | Parses the preset, connects, executes it through the shared `ActionExecutor`, disconnects. Reports Done or a failure reason. |
| Connect Device | Device | Connects BLE/Wi-Fi and reports the high-level connection summary ("Active Wi-Fi", "Ready Bluetooth", "Offline", …). |
| Check Device Status | Device (optional, defaults to active) | Same summary without changing preset state. |
| Send Keyboard Shortcut | Key combo string (e.g. `ENTER`, `CTRL+A`) | Validated with the same single-key rules as preset scripts; rejects anything else with a helpful message. |
| Send Text | Text (required), Typing Delay in ms (optional) | Types text through `sendText` with the selected host keyboard layout. |

Siri phrases registered via `AppShortcutsProvider`: "Run InputPilot preset",
"Connect InputPilot", "Send shortcut with InputPilot".

Unavailable cases never throw at the user: a missing active device answers "No
InputPilot device is saved yet", an unreachable device answers with the honest
connection failure instead of pretending success.

## Secrets

There is deliberately no "Get Secret Value" intent. Secret values never appear
in intent parameters, dialogs, entity suggestions or results. Running a
secret-backed preset resolves the value internally from the Keychain exactly
like the in-app Presets UI does; Shortcuts only ever sees the outcome.

## Background behavior (hardware verification pending)

App Intents run in-process. What iOS permits while the app is not foreground is
documented here only after real-device verification. **This section is pending
hardware evidence and must be filled in from the manual gate below before
making any claim in release notes.**

Known constraints to verify on hardware:

- [ ] Foreground: Run Preset over Bluetooth and Wi-Fi on a physical device.
- [ ] Background (app recently used): BLE connect + run, Wi-Fi connect + run,
      and the timeout behavior when the device is unreachable.
- [ ] Suspended/terminated launch from Shortcuts: whether the intent spins the
      app up in-process or fails gracefully.
- [ ] Authentication-failed device: verify the "Pair the device again over USB"
      guidance surfaces instead of a raw transport error.
- [ ] Siri phrase on a real device.

Be honest: whatever fails while backgrounded or suspended is documented here as
failing, with no lifecycle workarounds added to bypass iOS restrictions.

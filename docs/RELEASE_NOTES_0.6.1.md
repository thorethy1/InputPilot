# InputPilot v0.6.1

Stability release for the existing 0.6 feature set.

- BLE and TCP now wait for an explicit firmware authentication confirmation.
- Ordered HID sessions keep drag, text, presets, and macros on one transport.
- Interrupted sessions stop and attempt release-all before later failover.
- Capability messaging and older-firmware behavior are clearer.
- Radio, security, companion-app, and upstream attribution docs are corrected.
- Authentication and transport-ordering regression coverage is expanded.

Public release artifacts may include firmware, the Android APK, and the
unsigned `InputPilot-unsigned.ipa` for self-signing. Do not attach a personal
development-signed `InputPilot.ipa`; the manual signed-build workflow keeps
that IPA only as a private GitHub Actions artifact.

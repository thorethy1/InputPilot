# InputPilot 0.8.8

InputPilot 0.8.8 makes secure onboarding the default for new devices. Setup
captures the USB pairing frame first, limits Bluetooth discovery to that exact
device ID, and can provision Wi-Fi credentials inside the authenticated
AES-256-GCM BLE channel. No firmware API key is required.

Both supported transports remain available after pairing. Interactive control,
Keep Awake settings, and test actions use encrypted BLE or encrypted Wi-Fi/TCP.
BLE additionally requires an encrypted LE Secure Connections link. Paired
firmware continues to reject plaintext REST control and configuration.

Existing installations remain usable as a migration path. The app marks legacy
Bluetooth, TCP, REST, API-token, and Soft-AP operation as potentially
unencrypted, links to an in-app migration guide, and explains update, USB
pairing, recovery, and pairing-key rotation. New devices no longer enter the
legacy setup path by default.

Firmware advertises `secure_wifi_setup_v1` before the app offers encrypted Wi-Fi
provisioning. The compact length-prefixed BLE management frame supports spaces
and maximum-length Wi-Fi credentials within a common iOS ATT write.

Physical validation is required for secure onboarding, encrypted Wi-Fi
provisioning, BLE and Wi-Fi control, and upgrade/recovery before production use.

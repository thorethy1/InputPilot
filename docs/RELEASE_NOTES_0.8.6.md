# InputPilot 0.8.6 development

InputPilot 0.8.6 begins the secure-onboarding work without prematurely locking
devices. It also moves Keep Awake completely into persistent firmware settings.

## Implemented in the first development slice

- Independent firmware schedules for periodic pointer movement and left click.
- Persistent enabled state and interval for each action, both disabled by
  default (30-second movement and 60-second click defaults).
- REST and BLE command paths for changing the same firmware-owned settings.
- Native iOS toggles, interval pickers, and test-action buttons.
- Short transport labels: Bluetooth is **Ready** and Wi-Fi is **Online**.
- A non-enforcing USB pairing-input test using a BOOT-button-generated,
  128-bit hexadecimal test credential that is omitted from logs.
- A documented, hardware-gated plan for authenticated key exchange and encrypted
  BLE/Wi-Fi transport.

## Deliberately not enabled yet

Mandatory encryption and removal of the legacy optional API token are blocked
on physical iPhone USB validation. The current security posture in `SECURITY.md`
therefore remains applicable to this development build.

Android remains at its existing feature level while v0.8.6 development focuses
on firmware and iOS. Archiving the Android companion is a separate later task.


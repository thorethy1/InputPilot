# InputPilot v0.8.6 secure pairing design

## Status

This document began as the v0.8.6 implementation design. The physical iPhone
USB-input proof passed on 2026-08-28. v0.8.7 therefore activates pairing and a
capability-gated encrypted control channel. The existing `CONTROL_API_TOKEN`
behavior remains only as an unpaired upgrade path and is not described as
encryption.

## First trust

InputPilot generates a fresh 128-bit, single-use secret with the ESP32 hardware
random-number generator. It is represented as 32 uppercase hexadecimal
characters. A pairing frame contains:

1. the fixed `IPPAIR1` marker;
2. the 12-character device ID;
3. the 32-character one-time secret;
4. an 8-character corruption checksum; and
5. Enter.

The secret is emitted only after the BOOT button is held for two seconds after
normal USB startup. It is never advertised, returned by BLE or Wi-Fi, or written
to firmware/app logs. The development-only `pairtest` serial command emits the
same kind of HID frame for repeatable testing.

Two retrieval paths are required:

- Connect InputPilot to a computer, focus a text editor, hold BOOT, then copy or
  manually transfer the typed value to the iPhone.
- Connect InputPilot directly to an iPhone, open Settings → USB Pairing Input
  Test, and hold BOOT. UIKit receives InputPilot as a physical USB keyboard and
  validates the frame without retaining the secret.

From v0.8.7 onward, the iOS screen saves a valid credential in the
this-device-only Keychain. The firmware saves the same credential in NVS; a new
BOOT pairing action rotates it and invalidates the previous pairing.

## Target cryptographic exchange

The implemented v1 exchange uses the 128-bit USB credential as a per-device
pre-shared key. Independent 128-bit client and device nonces form an
HMAC-SHA-256 authenticated transcript, and HKDF-SHA-256 derives a fresh
AES-256-GCM session key. Strictly increasing counters provide replay rejection.
An asymmetric device identity and credential replacement exchange remain a
future hardening step; v1 intentionally does not claim forward secrecy.

A short numeric PIN is intentionally not used: without a reviewed PAKE it would
permit offline guessing if an attacker captured the transcript. The 128-bit
typed value has enough entropy to authenticate the exchange directly.

## Target transports

- BLE: LE Secure Connections and bonding plus application-level authenticated
  encryption, unique nonces, monotonically increasing counters, and replay
  rejection. Advertising and minimal discovery identity remain public.
- Wi-Fi REST: paired firmware rejects plaintext management and control. Minimal
  discovery identity remains public; HTTPS with a pinned per-device certificate
  remains future work.
- Wi-Fi stream control: the authenticated AES-GCM record layer is implemented;
  plaintext TCP control is rejected for paired devices.
- Secrets: iOS Keychain and protected device storage. No compile-time API key.

No input, OTA data, credentials, diagnostics, or management settings may use an
unauthenticated plaintext channel after secure mode becomes mandatory.

## Rollout gates

1. Validate USB HID capture on physical USB-C iPhones and documented adapters.
2. Validate the computer text-editor path and the BOOT-button timing.
3. Add key exchange behind a new advertised capability; keep legacy access
   available for recovery during development.
4. Add encrypted BLE records and pinned TLS; test replay and wrong-device cases.
5. Test upgrade, lost-phone, trust reset, and interrupted-pairing recovery.
6. Only then remove the optional unauthenticated default and compile-time token.

## Hardware test record

| Test | Result | Notes |
|---|---|---|
| USB-C iPhone powers and enumerates InputPilot | PASS | Physical test reported 2026-08-28 with the configured HID VID/PID |
| Pairing screen receives one complete frame | PASS | Physical test reported 2026-08-28; secret is not logged |
| Computer text editor receives one complete frame | NOT RUN | Test common host layouts |
| Two-second BOOT hold emits once per press | NOT RUN | Holding BOOT during plug-in enters bootloader; press after startup |
| Invalid/truncated frame is rejected | NOT RUN | No credential retained |

The current `0xCAFE:0x4001` identity is suitable for development testing and was
accepted by the tested iPhone. It is not evidence of an InputPilot-owned USB ID;
a product release must use VID/PID values the distributor is entitled to use.

# v0.8.11 architecture decision

The normative protocol and lifecycle are documented in [PROTOCOL.md](PROTOCOL.md).
The physical release gate is [HARDWARE_E2E.md](HARDWARE_E2E.md).

The architectural boundary is intentionally small:

`Device identity → USB trust secret → SecureSession → BLE or TCP → feature dispatcher`

Public discovery cannot mutate device state. Feature implementations do not
perform authentication and cannot select an insecure endpoint; they receive
requests only from an established SecureSession. OTA shares the same session
and the same firmware engine as ordinary controls.

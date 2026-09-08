# v0.8.11 architecture decision

The normative protocol and lifecycle are documented in [PROTOCOL.md](PROTOCOL.md).
The physical release gate is [HARDWARE_E2E.md](HARDWARE_E2E.md).

The architectural boundary is intentionally small:

`Device identity → USB trust secret → SecureSession → BLE or TCP → feature dispatcher`

Public discovery cannot mutate device state. Feature implementations do not
perform authentication and cannot select an insecure endpoint; they receive
requests only from an established SecureSession. OTA shares the same session
and the same firmware engine as ordinary controls.

## Fallback access point preference (0.9 RC work)

Authenticated BLE and TCP management sessions accept:

| Command | Reply | Effect |
| --- | --- | --- |
| `WIFI AP GET` | `{"enabled":true}` or `{"enabled":false}` | Read persisted preference; also serves as support detection. |
| `WIFI AP ON` | `ok` | Enable automatic fallback hotspot. |
| `WIFI AP OFF` | `ok` | Disable automatic fallback hotspot, including with no saved networks. |

Mutations persist the `wifi/fallback_ap` NVS boolean before acknowledgement, then
apply any necessary radio transition. Missing keys default to enabled for existing
installations. Saved networks, their retry policy and Bluetooth are independent of
this setting. Clearing networks does not reset it. Changes during OTA return
`error ota_busy`; persistence failures return `error wifi_storage_failed`.
Turning the AP off can close the requesting TCP connection; clients must display
an unconfirmed result if acknowledgement is lost and read status after reconnecting.
Older firmware reports an unsupported command. BLE discovery metadata is unchanged.

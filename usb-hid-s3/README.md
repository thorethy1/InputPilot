# usb-hid-s3

A composite **USB HID mouse + keyboard** device on the ESP32-S3 (native USB-OTG
via the ESP32 core USB stack — `USBHIDMouse` + `USBHIDKeyboard` + `USBCDC`), with
USB-CDC serial logging/commands, and concurrent or standalone WiFi/BLE connectivity
for remote control.

## Hardware

See [`docs/HARDWARE.md`](docs/HARDWARE.md) for the BOM, Amazon purchase link, LED
legend, and flash procedure.

Summary: **Waveshare ESP32-S3-Zero / Mini** (ESP32-S3FH4R2, 4 MB flash). Flash
needs **BOOT+RESET**, then a **power-cycle** so the device enumerates as
VID `0xCAFE` (not Espressif JTAG `0x303A`).

## Layout

```
usb-hid-s3/
  platformio.ini      # esp32s3 firmware env + native unit-test env
  include/            # Config.h, Logging.h (Arduino-side headers)
  src/main.cpp        # USB/HID/serial glue (hardware)
  lib/                # pure, unit-testable logic (CommandParser, JiggleEngine, RadioMode)
  test/               # PlatformIO native unit tests (pio test -e native)
  tests/              # pytest integration + on-Mac E2E
  scripts/            # deploy.sh, serial_monitor.sh, e2e.sh, install_test_deps.sh
  ../docs/PROTOCOL.md        # Secure Protocol v2 specification
  docs/HARDWARE.md           # BOM + flash notes
  docs/KNOWN_LIMITATIONS.md  # auth, VID, platform caveats
```

## Quick start

```bash
cp config.env.example config.env      # set ESP_PORT
./scripts/deploy.sh                    # build + upload
./scripts/serial_monitor.sh           # stream logs + send commands
./scripts/serial_monitor.sh -c "move 40 0"   # one-shot command
```

## Serial commands

`move <dx> <dy> [wheel]` · `click [left|right|middle]` · `type <text>` ·
`key <name>` · `jiggle on|off|status|interval <ms>` ·
`autoclick on|off|status|interval <ms>` · `pairtest` · `radio wifi|ble|none` ·
`wifi status|set|clear` · `status` · `version` · `help`

WiFi credentials persist in NVS. With no STA creds, `radio wifi` starts a
MAC-derived friendly Soft-AP such as `InputPilot-Dupe9` (open by default; set
`WIFI_AP_PASS` in `wifi_secrets.h` for WPA) with read-only discovery at
`http://192.168.4.1/api/status`.
With creds, STA joins and exposes:

- **Discovery HTTP** on `:80` — public product, protocol and device identity only.
- **Secure Protocol v2** on TCP `:3333` and BLE — authenticated encrypted
  setup, control, diagnostics, management and OTA after USB trust.

BLE, TCP, serial, jiggle, disconnect, and OTA safety paths enqueue into a
fixed 32-entry HID event queue. A dedicated executor task is the only runtime
context that calls the USB mouse/keyboard report APIs; adjacent mouse moves are
coalesced and six queue slots are reserved for release-critical events.

On STA the device also advertises **mDNS** as `inputpilot-xxxx.local` (lowercase
suffix; HTTP service on port 80 with TXT `path`, `id`, `fw`), so apps can
discover it without a hard-coded IP. `GET /api/status` returns `mdns` and
`device_id` (12 lowercase hex).

Optional Soft-AP WPA protection (compile-time, via `wifi_secrets.h`):

```c
#define WIFI_AP_PASS "setup-secret"       // Soft-AP WPA (8+ chars)
```

The Soft-AP is an optional fallback whenever every configured infrastructure
network is unavailable. It remains active while a phone is attached, and
periodic station retries never tear down its HTTP/TCP services. When the router
becomes reachable again, InputPilot returns to station mode. Wi-Fi credentials
and all other sensitive data are accepted exclusively through Secure Protocol
v2.

### Status LED (onboard WS2812, GPIO21)

| Appearance | Meaning |
|------------|---------|
| Fast amber blink | OTA firmware update active |
| Slow magenta blink | Optional fallback AP active (for example `InputPilot-Dupe9`) |
| Cyan breathing | Keep Awake movement or clicking enabled |
| Solid blue | Authenticated iOS controller connected over BLE or Wi-Fi |
| Dim solid green | At least one BLE/Wi-Fi control path is ready |
| Slow red blink | No control radio is currently ready |

Protocol and hardware validation: [`../docs/SECURE_PROTOCOL_V2.md`](../docs/SECURE_PROTOCOL_V2.md)

Public discovery example:

```bash
# Replace XXXX with your device suffix (from serial `status` or /api/status mdns field)
curl http://inputpilot-XXXX.local/api/status
```

All writes require an authenticated Secure Protocol v2 client; HTTP has no
write endpoints.

## Testing

```bash
pio test -e native                     # unit tests (host, no hardware)
./scripts/e2e.sh                       # pytest integration + E2E (needs board + Mac perms)
```

E2E on macOS uses `system_profiler`/`ioreg`/`hidutil` to verify enumeration and a
pyobjc `CGEventTap` to confirm the cursor actually moves and keystrokes arrive.
Grant your terminal **Input Monitoring** and **Accessibility** permission.

Cloud CI runs only the native unit tests + firmware compile (no Mac / no board).

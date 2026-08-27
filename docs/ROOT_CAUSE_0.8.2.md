# InputPilot 0.8.2 HID/BLE root-cause analysis

Baseline: `main` at `93e69f4077fe868c2e88c9843c071388c523f1d3`
(also tag `v0.8.1`). There were no commits after v0.8.1 at analysis start.

## End-to-end paths in v0.8.1

- Serial/TCP/REST text commands converge on `handleCommandLine`, create an
  `HIDEvent`, and enqueue it in the bounded HID queue.
- BLE binary Characteristics decoded complete frames inside the NimBLE host
  callback, performed string/KeyMap/logging work there, and then enqueued the
  same `HIDEvent`.
- `processHIDQueue` in Arduino `loop()` coalesces movement and executes all USB
  work. Mouse reports used `USBHIDMouse::sendReport`; raw keyboard and
  release-all used a separate `USBHID::SendReport`; text used
  `USBHIDKeyboard::write`.
- The iOS TCP and REST completion only proves transport acceptance. The v0.8.1
  BLE `send` method also returned immediately after `writeValue`, so its
  "delivered" log did not prove an ATT response or firmware/USB execution.

## USB HID finding

The pinned stack is pioarduino platform 54.03.21, Arduino-ESP32 3.2.1,
ESP-IDF 5.4 and NimBLE-Arduino 2.5.1. Arduino-ESP32 registers keyboard report ID
1 and relative mouse report ID 2 in one composite HID interface. The report
payloads are an 8-byte packed keyboard report and a 5-byte packed relative
mouse report. `USBHID` instances are lightweight facades over shared static
TinyUSB state, TX mutex and completion semaphore; multiple C++ objects do not
represent separate USB interfaces.

Therefore a report-ID collision or descriptor-size mismatch was not found in
v0.8.1. The mixed wrapper/direct-call design was legal in this Core version,
but obscured which send result was measured: `Keyboard.write` reports mapping
success, while its internal `sendReport` discards the USB result. v0.8.2 keeps
the core wrapper objects only to register their proven descriptors and sends
every actual mouse/keyboard report through one initialized `USBHID` handle.
Compile-time assertions pin IDs 1/2 and sizes 8/5. Attempt/success/failure
counters now reflect the real `USBHID::SendReport` return value.

This makes a remaining hardware failure classifiable. `usbReportsSucceeded=0`
means the host/interface was not ready or TinyUSB rejected/timed out the
report; a positive success count with no physical reaction points below the
API at enumeration/descriptor/host level and requires USB capture/hardware.

## BLE disconnect finding

Characteristics advertised both `WRITE` and `WRITE_NR` (CoreBluetooth
properties value 12). v0.8.1 always preferred `.withResponse`, launched an
unbounded sequence without waiting for `didWriteValueFor`, and returned
"delivered" immediately. Trackpad coalescing ran every 12 ms (up to about
83 writes/s). This is a concrete ATT flow-control violation and matches the
observed timeout after bursts.

v0.8.2 uses `.withoutResponse` only for coalesced movement/scroll, observes
`canSendWriteWithoutResponse`, and resumes when CoreBluetooth signals writer
readiness. Stateful events use `.withResponse`, with exactly one ATT request in
flight; completion is reported only from `didWriteValueFor`, with a bounded
timeout. Trackpad aggregation is 20 ms (50 Hz). Diagnostics now reuse the
existing per-device CoreBluetooth session instead of opening a competing
control/diagnostics connection.

## PANIC finding

The reset reason proves a panic occurred but is not itself a backtrace, so an
exact faulting instruction cannot honestly be claimed without the hardware
core dump. The strongest code-based candidate was the NimBLE callback path:
its 4 KiB host stack decoded STL strings, allocated an approximately 300-byte
HID event, ran KeyMap, logged through USB/RAM locks, and acquired the HID queue
mutex for every write. HID bursts exercise precisely that path.

v0.8.2 reduces the callback to authentication check, bounded frame copy and a
non-blocking FreeRTOS queue send. Decode, allocation, logging, KeyMap and HID
queue operations execute later in Arduino `loop()`. This also removes callback
reentrancy/lock contention as a panic source. A CRC-protected RTC breadcrumb
records BLE_RX, DECODE, QUEUE, HID_DEQUEUE, USB_MOUSE_REPORT,
USB_KEYBOARD_REPORT and DONE, then prints the previous event after reboot.

The existing `coredump` partition and pinned IDF configuration already enable
ELF core dumps to flash; no partition or OTA schema change is needed.
`usb-hid-s3/scripts/read_coredump.sh` decodes it against the exact build ELF.

## Hypotheses checked

- Report IDs, descriptor registration and struct padding: excluded by the
  pinned Core source and compile-time checks.
- Separate physical USB handles: excluded; Core state is shared static state.
- USB calls from NimBLE callbacks: excluded in v0.8.1; USB execution was already
  in Arduino `loop()`.
- Unbounded firmware HID queue: excluded; capacity is 32 with critical reserve,
  movement coalescing and release-all supersession.
- BLE advertising payload regression: no link found; the compact legacy
  advertising/scan-response implementation is unchanged.
- Core dump unavailable: excluded; IDF configuration enables flash ELF dumps
  and the 64 KiB partition exists.
- Exact PANIC instruction and physical USB-host behavior: unresolved until the
  v0.8.2 hardware matrix and, if needed, core-dump extraction are run.


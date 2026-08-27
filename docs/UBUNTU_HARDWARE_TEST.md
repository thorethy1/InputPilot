# Headless Ubuntu hardware test

`usb-hid-s3/scripts/hardware_test_ubuntu.py` proves the complete path instead
of treating a successful REST response or TCP write as HID success:

```text
test process -> REST/TCP -> ESP32 firmware -> USB HID -> Linux evdev
```

The Ubuntu machine must be both network client and USB host. Connect the
ESP32-S3 native USB data port and put Ubuntu on the same LAN as the device. The
script uses only the Python standard library.

## Run

```bash
cd usb-hid-s3
sudo ./scripts/hardware_test_ubuntu.py \
  --host 192.168.1.42 \
  --json-output tests/output/ubuntu-hardware.json
```

With `CONTROL_API_TOKEN`, avoid shell history:

```bash
read -rsp 'InputPilot token: ' INPUTPILOT_TOKEN; export INPUTPILOT_TOKEN
sudo --preserve-env=INPUTPILOT_TOKEN ./scripts/hardware_test_ubuntu.py --host 192.168.1.42
unset INPUTPILOT_TOKEN
```

Root is normally required for `/dev/input/event*`. Alternatively use the
`input` group and log in again. Explicit nodes can override VID/PID discovery:

```bash
./scripts/hardware_test_ubuntu.py --host inputpilot.local \
  --input-event /dev/input/event4 --input-event /dev/input/event5
```

## Coverage and proof

For REST and TCP the harness verifies raw Linux events for X/Y movement,
scrolling, left/right/middle click, mouse down/drag/up, a named key, text, a
modifier plus raw HID usage, and `releaseAll`. It also compares firmware
diagnostics: REST/TCP receive counters and successful USB reports must increase,
failed USB reports must not increase, and uptime must remain monotonic.

The JSON report records every observed event as evidence. Exit status is `0`
only when all checks pass, `1` for assertion failures, and `2` for a setup or
connection error. `--transport rest` and `--transport tcp` isolate one path.

Run this only on a headless host, or accept that the generated clicks and keys
can affect an active desktop session.

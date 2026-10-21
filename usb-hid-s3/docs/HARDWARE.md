# Hardware and initial setup

This guide expands the hardware overview in the [main README](../../README.md#1-hardware).

## Choosing a board

For new builds, choose an **ESP32-S3 with 8 MB flash**, preferably **N8R8
(8 MB flash, 8 MB PSRAM)**, to leave more room for future firmware development.
Existing **Waveshare ESP32-S3-Zero / Mini boards with ESP32-S3FH4R2** have
**4 MB flash and 2 MB PSRAM** and remain the current firmware target.

| Hardware | Flash | PSRAM | Role |
|----------|-------|-------|------|
| ESP32-S3 N8R8 | 8 MB | 8 MB | Recommended for new hardware; match the board to a compatible firmware release |
| Waveshare ESP32-S3-Zero / Mini, ESP32-S3FH4R2 | 4 MB | 2 MB | Existing firmware target; limited space for future firmware features |
| ESP32-S3 in a USB flash-drive form factor | Depends on the selected variant | Depends on the selected variant | Verify the chip, memory, native USB connection, and board pin assignments |

N8R8 and FH4R2 identify different memory configurations. The FH4R2 board is
not an 8 MB board. See [Espressif's N8R8 memory table](https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s3/esp32-s3-devkitc-1/user_guide_v1.0.html)
and [Waveshare's ESP32-S3-Zero specifications](https://docs.waveshare.com/ESP32-S3-Zero?variant=ESP32-S3-Zero-M).

**Buy ESP32-S3, not ESP32-C3.** InputPilot uses native USB-OTG for its keyboard
and mouse. A USB connector or a USB-to-UART interface alone does not provide
that functionality. If a board has separate USB ports, use the **native
ESP32-S3 USB port** for HID; [Espressif documents the port distinction](https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s3/esp32-s3-devkitc-1/user_guide_v1.0.html).

### Purchase examples

These are the same listings as in the main README. Check the selected product
variant before ordering; one listing may contain multiple chip or memory options.

- [8 MB version — recommended](https://s.click.aliexpress.com/e/_EwoijzC): **select N8R8**.
- [4 MB version — existing hardware](https://s.click.aliexpress.com/e/_EJBgoCE): select **ESP32-S3**.
- [USB flash-drive version](https://s.click.aliexpress.com/e/_EulrxZs): verify the ESP32-S3 and memory variant.

<p align="center">
  <img src="https://github.com/user-attachments/assets/96cdada5-197d-4781-a58c-be7e480f77f1" alt="Board selection reference for the hardware listings" width="720">
</p>

### Firmware compatibility

The current repository configuration still targets **4 MB flash**:

- [`platformio.ini`](../platformio.ini) sets flash size to `4MB` and uses [`ota_4MB.csv`](../ota_4MB.csv).
- [`Config.h`](../include/Config.h) and the release manifests identify the board as `esp32-s3-zero-4mb`.
- The configured status LED is a **WS2812 on GPIO21**; USB trust uses **BOOT on GPIO0**.

The 8 MB purchase recommendation does not itself introduce an 8 MB firmware
layout or enable additional PSRAM. Do not treat every ESP32-S3 board as
interchangeable: check the release's board requirements, native USB wiring,
BOOT button, and LED pin assignments. Extra physical flash is not used by the
current 4 MB partition layout. For another board, the firmware configuration
and validation must match that hardware.

The existing 4 MB Waveshare board looks like this:

<p align="center">
  <img src="https://docs.waveshare.com/assets/images/ESP32-S3-Zero-M-dc5172b1f2c465b7927cc20a567c6322.webp" alt="Existing Waveshare ESP32-S3-Zero board with 4 MB flash" width="360">
</p>

## What you need

| Item | Notes |
|------|-------|
| ESP32-S3 board | Choose the memory variant above and a compatible firmware release |
| USB data cable or suitable USB adapter | Charge-only cables cannot flash the board or carry USB HID input |
| Desktop computer with Chrome or Edge | Used for the initial installation with the Web Flasher |
| Computer to control | InputPilot plugs into its USB port and appears as a keyboard and mouse |
| iPhone with Bluetooth | Used for USB trust, secure pairing, and local control; a compatible USB adapter may be needed |
| Wi-Fi network, optional | Bluetooth-only setup works without Wi-Fi; optional Wi-Fi setup uses a 2.4 GHz network |

## First installation: Web Flasher

Use the **InputPilot Web Flasher** ([Deutsch](https://thorethy1.github.io/InputPilot/)
· [English](https://thorethy1.github.io/InputPilot/en/)) in **Chrome or Edge on a
desktop computer**. No PlatformIO installation or local firmware build is needed.

1. Open the flasher and connect the compatible ESP32-S3 board with a USB data cable.
2. If the board is not detected, hold **BOOT**, press and release **RESET**, then
   release **BOOT**. Alternatively, unplug the board, hold BOOT while reconnecting,
   then release BOOT.
3. Select the board's serial port in the browser and install the latest stable
   `InitialFirmware.bin`. Wait until installation finishes.
4. Disconnect and reconnect the board so it boots the InputPilot application.
5. Open the iOS app and follow the guided setup: connect InputPilot to the iPhone
   by USB, focus the pairing field, and hold **BOOT for two seconds** to send the
   trust code. After pairing, move InputPilot to the computer you want to control.
   Bluetooth is sufficient; Wi-Fi can be added during setup or later.

`InitialFirmware.bin` includes the bootloader, partition table, OTA bootstrap
image, and application. It is for initial USB installation and recovery.
It is different from the app-only `firmware.bin` used for later OTA updates.

## Alternative: install from a GitHub Release

Download `InitialFirmware.bin` from the desired [InputPilot release](https://github.com/thorethy1/InputPilot/releases)
and enter download mode as described above. For a first installation or a
required full reflash, erase the old installation and write the complete image:

```bash
python3 -m venv ~/esptool-env
source ~/esptool-env/bin/activate
python -m pip install esptool

# Replace /dev/ttyACM0 with the board's serial port.
esptool --chip esp32s3 --port /dev/ttyACM0 erase-flash
esptool --chip esp32s3 --port /dev/ttyACM0 --baud 460800 write-flash 0x0 InitialFirmware.bin
```

Erasing flash removes saved device settings, including Wi-Fi and USB trust;
complete secure setup again afterward. Serial ports are typically
`/dev/ttyACM0` or `/dev/ttyUSB0` on Linux, `/dev/cu.usbmodem…` on macOS, and
`COM…` on Windows. Use the appropriate Python environment activation command
on your platform.

Alternatively, extract `InputPilot-Firmware-vX.Y.Z.zip` and use the individual
images with the offsets recorded in its `initial-flash-manifest.json` and
`flash_args`. The current 4 MB release layout uses:

```bash
esptool --chip esp32s3 --port /dev/ttyACM0 write-flash \
  0x0000 bootloader.bin \
  0x8000 partitions.bin \
  0xe000 boot_app0.bin \
  0x10000 firmware.bin
```

Use the files and manifest from the same release. Disconnect and reconnect the
board after flashing. For later updates, use the iOS **Firmware** tab, which
transfers only the app-only `firmware.bin` over authenticated Bluetooth or Wi-Fi.
Never select `InitialFirmware.bin`, a bootloader, a partition table, or
`boot_app0.bin` as an OTA update.

## Developer build (USB-OTG)

The current `esp32s3` environment builds the 4 MB target described above.
From `usb-hid-s3/`:

```bash
pio run -e esp32s3
pio run -e esp32s3 -t upload
# Or use the project's build/upload helper:
./scripts/deploy.sh
```

Auto-reset into download mode can fail when native USB-OTG is active. Hold
**BOOT**, tap **RESET**, and release **BOOT** before retrying the upload.
Then disconnect and reconnect the board.

With the default USB identity, the running InputPilot application enumerates
as **VID `0xCAFE` / PID `0x4001`**, product **InputPilot**. The Espressif
bootloader/debug identity (`0x303A`) is different. The app can customize the
application's USB identity; those values may therefore differ on a configured
device. [`flash_and_verify.sh`](../scripts/flash_and_verify.sh) checks the
default VID after flashing on macOS.

## Panic core dump

Use the release gate in [`../../docs/HARDWARE_E2E.md`](../../docs/HARDWARE_E2E.md).

The pinned Arduino-ESP32/IDF build already enables ELF core dumps to the
`coredump` partition at `0x3d0000` (size `0x10000`). Build the exact source
revision that crashed, install Espressif's decoder, and read it directly:

```bash
python3 -m pip install esp-coredump
./scripts/read_coredump.sh /dev/ttyACM0 .pio/build/esp32s3/firmware.elf
```

Do not decode against a different build: addresses and stacks will not match.

## Status LED

| Appearance | Meaning |
|------------|---------|
| Fast amber blink | OTA firmware update active |
| Brief violet pulse (180 ms every 4 seconds) | Optional fallback AP active (for example `InputPilot-Halo9`); normal status resumes between pulses |
| Cyan breathing | Keep Awake movement or clicking enabled |
| Solid blue | Authenticated iOS controller connected over BLE or Wi-Fi |
| Dim solid green | At least one BLE/Wi-Fi control path is ready |
| Slow red blink | No control radio is currently ready |

The AP pulse briefly overlays the normal status (blue, breathing cyan, or dim
green). OTA updates take priority: amber blinking continues without AP pulses.

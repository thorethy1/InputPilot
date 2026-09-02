# Hardware

## Supported board

**Waveshare ESP32-S3-Zero / Mini** (ESP32-S3FH4R2):

![Waveshare ESP32-S3-Zero with USB-C connected](https://docs.waveshare.com/assets/images/ESP32-S3-Zero-M-dc5172b1f2c465b7927cc20a567c6322.webp)

- Dual-core Xtensa LX7 up to 240 MHz
- 4 MB flash, 2 MB PSRAM
- Native USB-OTG (USB-C)
- Onboard WS2812 RGB LED on **GPIO21**
- Ceramic antenna (WiFi + BLE)

Purchase example (3-pack):  
[Waveshare ESP32-S3 Mini on Aliexpress](https://a.aliexpress.com/_ExnnLN0)

Official Waveshare wiki / product page is also fine if you buy elsewhere — match
**ESP32-S3FH4R2**, **4 MB flash**, and the WS2812 on GPIO21 pinout.

## What you need

| Item | Notes |
|------|--------|
| ESP32-S3-Zero/Mini board | Above |
| USB-C data cable | Charge-only cables will not enumerate |
| Host PC | USB HID target (mouse/keyboard appear here) |
| iPhone on Wi-Fi/Bluetooth | Secure setup and control after USB trust |

## Developer build (USB-OTG)

Auto-reset into download mode usually **fails** in native USB-OTG mode:

1. Hold **BOOT**, tap **RESET**, release **BOOT** (or unplug → hold BOOT →
   replug → release BOOT).
2. Upload firmware (`pio run -e esp32s3 -t upload` or `./scripts/deploy.sh`).
3. **Power-cycle** the board (unplug/replug) so the app boots in OTG mode.

After power-cycle the host should see USB identity **VID `0xCAFE` / PID `0x4001`**
(“InputPilot S3”), not Espressif’s JTAG CDC (`0x303A`).

`scripts/flash_and_verify.sh` waits for that enumeration after you power-cycle.

## Installing from a GitHub Release

Release users do not need PlatformIO. Enter download mode as described above and erase the device when installing for the first time or migrating from the old partition layout.

The preferred single-image method is:

```bash
esptool --chip esp32s3 erase-flash
esptool --chip esp32s3 write-flash 0x0 InputPilot-v0.8.11-initial-flash.bin
```

Alternatively, extract the v0.8.11 initial-flash archive and flash the individual images. These offsets are exported from the pinned build and recorded in `initial-flash-manifest.json` and `flash_args`:

```bash
esptool --chip esp32s3 write-flash \
  0x0000 bootloader.bin \
  0x8000 partitions.bin \
  0xe000 boot_app0.bin \
  0x10000 firmware.bin
```

Power-cycle after flashing. Future releases use only `firmware.bin` in the iOS Firmware tab; never use the merged image or the other three `.bin` files for OTA.

### Panic core dump

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
| Slow magenta blink | Optional fallback AP active (for example `InputPilot-Halo9`) |
| Cyan breathing | Keep Awake movement or clicking enabled |
| Solid blue | Authenticated iOS controller connected over BLE or Wi-Fi |
| Dim solid green | At least one BLE/Wi-Fi control path is ready |
| Slow red blink | No control radio is currently ready |

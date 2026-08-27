#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <serial-port> [firmware.elf]" >&2
  exit 2
fi

serial_port=$1
firmware_elf=${2:-.pio/build/esp32s3/firmware.elf}

if [[ ! -f "$firmware_elf" ]]; then
  echo "firmware ELF not found: $firmware_elf" >&2
  echo "build the exact crashed revision with: pio run -e esp32s3" >&2
  exit 2
fi

if command -v esp-coredump >/dev/null 2>&1; then
  coredump_tool=esp-coredump
elif command -v espcoredump.py >/dev/null 2>&1; then
  coredump_tool=espcoredump.py
else
  echo "ESP core-dump decoder not found. Install it with: python3 -m pip install esp-coredump" >&2
  exit 2
fi

"$coredump_tool" --chip esp32s3 -p "$serial_port" -o 0x3d0000 \
  info_corefile "$firmware_elf"

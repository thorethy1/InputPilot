#ifndef CONFIG_H
#define CONFIG_H

/**
 * Compile-time configuration for the USB HID S3 firmware.
 * Values the test suite reads back (FW_VERSION) live here.
 */

#define FW_VERSION      "0.8.8"
#define FW_NAME         "InputPilot-Firmware"
// USB bcdDevice reported to the host.
#define FW_VERSION_BCD  0x0808
#ifndef FW_GIT_COMMIT
#define FW_GIT_COMMIT   "unknown"
#endif
#define OTA_SCHEMA_VERSION 1
#define OTA_PROTOCOL_VERSION 1
#define FW_PRODUCT      "InputPilot"
#define FW_BOARD        "esp32-s3-zero-4mb"
#define FW_METADATA_PREFIX "INPUTPILOT-META:"

// --- USB identity (custom VID/PID so the host drops the boot-time Espressif id) ---
// Prefixed to avoid colliding with USB_VID/USB_PID/... from the S3 variant's
// pins_arduino.h.
#define HID_USB_VID          0xCAFE
#define HID_USB_PID          0x4001
#define HID_USB_MANUFACTURER "MKF Labs"
#define HID_USB_PRODUCT      "InputPilot"

// --- HID report IDs (composite descriptor) ---
#define HID_RID_KEYBOARD 1
#define HID_RID_MOUSE    2

// --- Jiggle behaviour (Phase 1) ---
#define JIGGLE_INTERVAL_MS 30000UL  // default time between pointer movements
#define JIGGLE_MAX_DELTA   8         // max +/- pixels per jiggle step
#define JIGGLE_ENABLED_DEFAULT 0     // 0 = off at boot; toggle via serial
#define CLICK_INTERVAL_MS 60000UL    // default time between automatic left clicks
#define CLICK_ENABLED_DEFAULT 0      // automatic clicks are opt-in
#define KEEP_AWAKE_MIN_INTERVAL_MS 5000UL
#define KEEP_AWAKE_MAX_INTERVAL_MS 3600000UL
#define PAIRING_BUTTON_PIN 0
#define PAIRING_BUTTON_HOLD_MS 2000UL

// --- Serial command interface ---
#define SERIAL_BAUD        115200
#define SERIAL_CMD_MAXLEN  256

// --- Radio: "none" / "wifi" / "ble" / "wifi+ble" selected at runtime.
//     The CLI aliases the combined mode as `radio both`. ---
#define RADIO_MODE_DEFAULT_STR "wifi+ble"

// WiFi STA credentials. Empty by default (radio stays disconnected).
// To set them without leaking secrets into git, create an untracked
// include/wifi_secrets.h (gitignored) with:
//   #define WIFI_SSID "MyNetwork"
//   #define WIFI_PASS "supersecret"
// It's pulled in below if present; the #ifndef guards keep these as the
// fallback. (Build flags -DWIFI_SSID=... also work.)
#if defined(__has_include)
#  if __has_include("wifi_secrets.h")
#    include "wifi_secrets.h"
#  endif
#endif
#ifndef WIFI_SSID
#define WIFI_SSID ""
#endif
#ifndef WIFI_PASS
#define WIFI_PASS ""
#endif
#ifndef WIFI_AP_PASS
#define WIFI_AP_PASS ""  // empty = open Soft-AP (easiest phone setup)
#endif
#ifndef CONTROL_API_TOKEN
#define CONTROL_API_TOKEN ""  // empty = no HTTP/TCP/BLE auth
#endif
#define WIFI_CONNECT_TIMEOUT_MS 15000UL

// Soft-AP / mDNS prefixes. Runtime SSIDs/hostnames append a MAC suffix via
// DeviceIdentity (e.g. InputPilot-EEFF, inputpilot-eeff.local).
#define WIFI_AP_SSID_PREFIX  "InputPilot-"
#define MDNS_HOSTNAME_PREFIX "inputpilot-"
#define WIFI_AP_CHANNEL  1
#define WIFI_HTTP_PORT   80

// Waveshare ESP32-S3-Zero / Mini: onboard WS2812 RGB on GPIO21.
#define STATUS_LED_PIN         21
#define STATUS_LED_BRIGHTNESS  48   // 0..255 peak channel value (keep modest)

// BLE identity + Nordic UART Service (NUS) UUIDs for remote control (Phase 4).
#define BLE_DEVICE_NAME  "InputPilot-Firmware"
#define BLE_NUS_SERVICE_UUID "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define BLE_NUS_RX_UUID      "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  // host -> device (write)
#define BLE_NUS_TX_UUID      "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  // device -> host (notify)
#define SECURE_CHANNEL_VERSION 1

// InputPilot Control Service v1. NUS remains for backwards compatibility.
#define BLE_HID_SERVICE_UUID  "7d9f0001-4f4d-4f56-4552-484944000001"
#define BLE_HID_CONTROL_UUID  "7d9f0002-4f4d-4f56-4552-484944000001"
#define BLE_HID_MOUSE_UUID    "7d9f0003-4f4d-4f56-4552-484944000001"
#define BLE_HID_KEYBOARD_UUID "7d9f0004-4f4d-4f56-4552-484944000001"
#define BLE_HID_STATUS_UUID   "7d9f0005-4f4d-4f56-4552-484944000001"

// InputPilot authenticated BLE OTA service v1. These UUIDs are stable public
// protocol identifiers and must match BLEFirmwareUpdater.swift.
#define BLE_OTA_SERVICE_UUID "7d9f1001-4f4d-4f56-4552-484944000001"
#define BLE_OTA_CONTROL_UUID "7d9f1002-4f4d-4f56-4552-484944000001"
#define BLE_OTA_DATA_UUID    "7d9f1003-4f4d-4f56-4552-484944000001"
#define BLE_OTA_STATUS_UUID  "7d9f1004-4f4d-4f56-4552-484944000001"
#define BLE_OTA_TIMEOUT_MS 15000UL
#define BLE_OTA_ACK_BYTES (32UL * 1024UL)

// InputPilot read-only diagnostics. Not included in the compact advertisement.
#define BLE_DIAGNOSTICS_SERVICE_UUID "7d9f2001-4f4d-4f56-4552-484944000001"
#define BLE_DIAGNOSTICS_INFO_UUID    "7d9f2002-4f4d-4f56-4552-484944000001"
#define BLE_DIAGNOSTICS_LOG_UUID     "7d9f2003-4f4d-4f56-4552-484944000001"

// WiFi STA control: TCP line server (same command grammar as serial).
#define WIFI_CONTROL_PORT 3333

#endif // CONFIG_H

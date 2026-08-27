#ifndef LOGGING_H
#define LOGGING_H

void firmwareLog(const char *level, const char *tag, const char *format, ...);

/**
 * Tagged logging for the USB HID S3 firmware.
 *
 * Format: [<millis>][<LEVEL>][<TAG>] message
 * The pytest serial harness greps against this format, so keep it stable.
 * Set DEBUG_LOGGING to 0 to compile out the *_DEBUG variants.
 *
 * Logs go to UsbSerial (our explicit USB-CDC), not the Arduino `Serial`:
 * ARDUINO_USB_CDC_ON_BOOT is 0 so we own the whole USB bring-up (identity +
 * HID + CDC) in setup() before the single USB.begin(). UsbSerial is defined in
 * main.cpp.
 */

#ifndef DEBUG_LOGGING
#define DEBUG_LOGGING 1
#endif

#define _LOG_PRINT(level, tag, fmt, ...) \
  firmwareLog(level, tag, fmt, ##__VA_ARGS__)

#if DEBUG_LOGGING
  #define LOG_DEBUG(fmt, ...)       _LOG_PRINT("DEBUG", "APP", fmt, ##__VA_ARGS__)
  #define LOG_USB_DEBUG(fmt, ...)   _LOG_PRINT("DEBUG", "USB", fmt, ##__VA_ARGS__)
  #define LOG_HID_DEBUG(fmt, ...)   _LOG_PRINT("DEBUG", "HID", fmt, ##__VA_ARGS__)
  #define LOG_CMD_DEBUG(fmt, ...)   _LOG_PRINT("DEBUG", "CMD", fmt, ##__VA_ARGS__)
  #define LOG_RADIO_DEBUG(fmt, ...) _LOG_PRINT("DEBUG", "RADIO", fmt, ##__VA_ARGS__)
#else
  #define LOG_DEBUG(fmt, ...)       do {} while (0)
  #define LOG_USB_DEBUG(fmt, ...)   do {} while (0)
  #define LOG_HID_DEBUG(fmt, ...)   do {} while (0)
  #define LOG_CMD_DEBUG(fmt, ...)   do {} while (0)
  #define LOG_RADIO_DEBUG(fmt, ...) do {} while (0)
#endif

#define LOG_INFO(fmt, ...)   _LOG_PRINT("INFO", "APP", fmt, ##__VA_ARGS__)
#define LOG_WARN(fmt, ...)   _LOG_PRINT("WARN", "APP", fmt, ##__VA_ARGS__)
#define LOG_ERROR(fmt, ...)  _LOG_PRINT("ERROR", "APP", fmt, ##__VA_ARGS__)

#define LOG_USB(fmt, ...)    _LOG_PRINT("INFO", "USB", fmt, ##__VA_ARGS__)
#define LOG_HID(fmt, ...)    _LOG_PRINT("INFO", "HID", fmt, ##__VA_ARGS__)
#define LOG_CMD(fmt, ...)    _LOG_PRINT("INFO", "CMD", fmt, ##__VA_ARGS__)
#define LOG_JIG(fmt, ...)    _LOG_PRINT("INFO", "JIG", fmt, ##__VA_ARGS__)
#define LOG_RADIO(fmt, ...)  _LOG_PRINT("INFO", "RADIO", fmt, ##__VA_ARGS__)
#define LOG_WIFI(fmt, ...)   _LOG_PRINT("INFO", "WIFI", fmt, ##__VA_ARGS__)
#define LOG_BLE(fmt, ...)    _LOG_PRINT("INFO", "BLE", fmt, ##__VA_ARGS__)
#define LOG_OTA(fmt, ...)    _LOG_PRINT("INFO", "OTA", fmt, ##__VA_ARGS__)
#define LOG_OTA_WARN(fmt, ...) _LOG_PRINT("WARN", "OTA", fmt, ##__VA_ARGS__)

#endif // LOGGING_H

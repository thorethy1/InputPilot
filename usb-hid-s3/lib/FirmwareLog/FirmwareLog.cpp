#include "FirmwareLog.h"

#ifndef UNIT_TEST
#include <Arduino.h>
#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <esp_attr.h>

#include "USBCDC.h"

extern USBCDC UsbSerial;

namespace {
FirmwareLogBuffer s_logs;
portMUX_TYPE s_logMux = portMUX_INITIALIZER_UNLOCKED;

// Keep a useful tail in RTC memory so diagnostics from the run that panicked,
// watchdog-reset or software-restarted remain available after boot. The full
// in-memory buffer is intentionally larger; RTC slow memory is scarce.
constexpr uint32_t kRTCLogMagic = 0x49504C47;  // "IPLG"
constexpr uint16_t kRTCLogVersion = 1;
constexpr size_t kRTCLogCapacity = 20;
struct RTCFirmwareLogEntry { char line[FirmwareLogBuffer::LineBytes]; };
struct RTCFirmwareLogStore {
  uint32_t magic;
  uint16_t version;
  uint16_t count;
  uint16_t writeIndex;
  uint16_t reserved;
  RTCFirmwareLogEntry entries[kRTCLogCapacity];
  uint32_t checksum;
};
RTC_NOINIT_ATTR static RTCFirmwareLogStore s_rtcLogs;
bool s_rtcReady = false;

uint32_t rtcChecksum(const RTCFirmwareLogStore &store) {
  const uint8_t *bytes = reinterpret_cast<const uint8_t *>(&store);
  uint32_t checksum = 2166136261u;
  for (size_t i = 0; i < offsetof(RTCFirmwareLogStore, checksum); ++i)
    checksum = (checksum ^ bytes[i]) * 16777619u;
  return checksum;
}

void commitRTCLogs() { s_rtcLogs.checksum = rtcChecksum(s_rtcLogs); }

void resetRTCLogs() {
  std::memset(&s_rtcLogs, 0, sizeof(s_rtcLogs));
  s_rtcLogs.magic = kRTCLogMagic;
  s_rtcLogs.version = kRTCLogVersion;
  commitRTCLogs();
}

void restoreRTCLogsOnce() {
  if (s_rtcReady) return;
  s_rtcReady = true;
  const bool valid = s_rtcLogs.magic == kRTCLogMagic &&
                     s_rtcLogs.version == kRTCLogVersion &&
                     s_rtcLogs.count <= kRTCLogCapacity &&
                     s_rtcLogs.writeIndex < kRTCLogCapacity &&
                     s_rtcLogs.checksum == rtcChecksum(s_rtcLogs);
  if (!valid) {
    resetRTCLogs();
    return;
  }
  const size_t oldest =
      (s_rtcLogs.writeIndex + kRTCLogCapacity - s_rtcLogs.count) % kRTCLogCapacity;
  for (size_t i = 0; i < s_rtcLogs.count; ++i)
    s_logs.append(s_rtcLogs.entries[(oldest + i) % kRTCLogCapacity].line);
}

void appendRTCLog(const char *line) {
  RTCFirmwareLogEntry &entry = s_rtcLogs.entries[s_rtcLogs.writeIndex];
  std::strncpy(entry.line, line ? line : "", sizeof(entry.line) - 1);
  entry.line[sizeof(entry.line) - 1] = '\0';
  s_rtcLogs.writeIndex = (s_rtcLogs.writeIndex + 1) % kRTCLogCapacity;
  if (s_rtcLogs.count < kRTCLogCapacity) ++s_rtcLogs.count;
  commitRTCLogs();
}
}

void firmwareLog(const char *level, const char *tag, const char *format, ...) {
  char message[384];
  va_list args;
  va_start(args, format);
  vsnprintf(message, sizeof(message), format, args);
  va_end(args);

  char line[512];
  snprintf(line, sizeof(line), "[%lu][%s][%s] %s",
           static_cast<unsigned long>(millis()), level, tag, message);
  UsbSerial.printf("%s\n", line);
  portENTER_CRITICAL(&s_logMux);
  restoreRTCLogsOnce();
  s_logs.append(line);
  appendRTCLog(line);
  portEXIT_CRITICAL(&s_logMux);
}

size_t firmwareLogCopySince(uint32_t cursor, FirmwareLogEntry *out, size_t maxEntries) {
  portENTER_CRITICAL(&s_logMux);
  restoreRTCLogsOnce();
  const size_t count = s_logs.copySince(cursor, out, maxEntries);
  portEXIT_CRITICAL(&s_logMux);
  return count;
}

uint32_t firmwareLogLatestSequence() {
  portENTER_CRITICAL(&s_logMux);
  restoreRTCLogsOnce();
  const uint32_t sequence = s_logs.latestSequence();
  portEXIT_CRITICAL(&s_logMux);
  return sequence;
}

void firmwareLogClear() {
  portENTER_CRITICAL(&s_logMux);
  restoreRTCLogsOnce();
  s_logs.clear();
  resetRTCLogs();
  portEXIT_CRITICAL(&s_logMux);
}
#endif

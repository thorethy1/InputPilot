#include "FirmwareLog.h"

#ifndef UNIT_TEST
#include <Arduino.h>
#include <cstdarg>
#include <cstdio>

#include "USBCDC.h"

extern USBCDC UsbSerial;

namespace {
FirmwareLogBuffer s_logs;
portMUX_TYPE s_logMux = portMUX_INITIALIZER_UNLOCKED;
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
  s_logs.append(line);
  portEXIT_CRITICAL(&s_logMux);
}

size_t firmwareLogCopySince(uint32_t cursor, FirmwareLogEntry *out, size_t maxEntries) {
  portENTER_CRITICAL(&s_logMux);
  const size_t count = s_logs.copySince(cursor, out, maxEntries);
  portEXIT_CRITICAL(&s_logMux);
  return count;
}

uint32_t firmwareLogLatestSequence() {
  portENTER_CRITICAL(&s_logMux);
  const uint32_t sequence = s_logs.latestSequence();
  portEXIT_CRITICAL(&s_logMux);
  return sequence;
}

void firmwareLogClear() {
  portENTER_CRITICAL(&s_logMux);
  s_logs.clear();
  portEXIT_CRITICAL(&s_logMux);
}
#endif

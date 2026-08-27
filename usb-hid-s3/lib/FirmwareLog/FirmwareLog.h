#ifndef FIRMWARE_LOG_H
#define FIRMWARE_LOG_H

#include <cstddef>
#include <cstdint>

#include "FirmwareLogBuffer.h"

void firmwareLog(const char *level, const char *tag, const char *format, ...);
size_t firmwareLogCopySince(uint32_t cursor, FirmwareLogEntry *out, size_t maxEntries);
uint32_t firmwareLogLatestSequence();
void firmwareLogClear();

#endif

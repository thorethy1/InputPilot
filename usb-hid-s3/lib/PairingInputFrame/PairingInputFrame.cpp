#include "PairingInputFrame.h"

#include <cstdio>
#include <cstring>

uint32_t PairingInputFrame::checksum(const uint8_t secret[SecretSize]) {
  uint32_t value = 2166136261u;
  for (size_t i = 0; i < SecretSize; ++i)
    value = (value ^ secret[i]) * 16777619u;
  return value;
}

bool PairingInputFrame::format(const char *deviceId,
                               const uint8_t secret[SecretSize],
                               char *output,
                               size_t outputSize) {
  if (!deviceId || !secret || !output || outputSize <= EncodedLength ||
      strlen(deviceId) != DeviceIdLength) return false;
  size_t offset = static_cast<size_t>(snprintf(output, outputSize, "IPPAIR1%s", deviceId));
  for (size_t i = 0; i < SecretSize; ++i)
    offset += static_cast<size_t>(snprintf(output + offset, outputSize - offset, "%02X", secret[i]));
  snprintf(output + offset, outputSize - offset, "%08lX\n",
           static_cast<unsigned long>(checksum(secret)));
  return strlen(output) == EncodedLength;
}

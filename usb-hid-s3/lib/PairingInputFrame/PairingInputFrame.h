#ifndef PAIRING_INPUT_FRAME_H
#define PAIRING_INPUT_FRAME_H

#include <cstddef>
#include <cstdint>

class PairingInputFrame {
public:
  static constexpr size_t SecretSize = 16;
  static constexpr size_t DeviceIdLength = 12;
  static constexpr size_t EncodedLength = 60;  // includes trailing newline

  static uint32_t checksum(const uint8_t secret[SecretSize]);
  static bool format(const char *deviceId,
                     const uint8_t secret[SecretSize],
                     char *output,
                     size_t outputSize);
};

#endif

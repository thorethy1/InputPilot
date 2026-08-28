#ifndef PAIRING_SECRET_STORE_H
#define PAIRING_SECRET_STORE_H

#include <cstddef>
#include <cstdint>

class PairingSecretStore {
public:
  static constexpr size_t SecretSize = 16;

  static bool hasSecret();
  static bool load(uint8_t output[SecretSize]);
  static bool replace(const uint8_t secret[SecretSize]);
  static bool clear();
};

#endif

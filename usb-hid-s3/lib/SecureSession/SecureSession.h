#ifndef INPUTPILOT_SECURE_SESSION_H
#define INPUTPILOT_SECURE_SESSION_H

#include <cstddef>
#include <cstdint>
#include <string>

class SecureSession {
public:
  static constexpr size_t SecretSize = 16;
  static constexpr size_t NonceSize = 16;
  static constexpr size_t KeySize = 32;
  static constexpr size_t TagSize = 16;
  static constexpr uint8_t BinaryVersion = 0xA1;

  void reset();
  bool begin(const uint8_t secret[SecretSize], const char *deviceId,
             std::string &challengeReply);
  bool acceptHello(const std::string &line, std::string &serverReply);
  bool decryptText(const std::string &line, std::string &plaintext);
  bool encryptText(const std::string &plaintext, std::string &line);
  bool encryptBinary(const uint8_t *plaintext, size_t plaintextLength,
                     uint8_t *record, size_t recordCapacity,
                     size_t &recordLength);
  bool decryptBinary(const uint8_t *record, size_t recordLength,
                     uint8_t *plaintext, size_t plaintextCapacity,
                     size_t &plaintextLength);
  bool established() const { return established_; }

private:
  bool decrypt(uint64_t counter, const uint8_t *ciphertext, size_t length,
               const uint8_t tag[TagSize], uint8_t *plaintext);

  uint8_t secret_[SecretSize]{};
  uint8_t serverNonce_[NonceSize]{};
  uint8_t receiveKey_[KeySize]{};
  uint8_t sendKey_[KeySize]{};
  char deviceId_[13]{};
  uint64_t receiveCounter_ = 0;
  uint64_t sendCounter_ = 0;
  bool started_ = false;
  bool established_ = false;
};

#endif

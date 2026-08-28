#include "SecureSession.h"

#include <cstring>
#include <esp_random.h>
#include <mbedtls/gcm.h>
#include <mbedtls/hkdf.h>
#include <mbedtls/md.h>

namespace {
constexpr char ClientProofLabel[] = "IPSEC1-C";
constexpr char ServerProofLabel[] = "IPSEC1-S";
constexpr char KdfInfo[] = "InputPilot secure channel v1";

std::string hex(const uint8_t *data, size_t length) {
  static constexpr char digits[] = "0123456789ABCDEF";
  std::string output(length * 2, '0');
  for (size_t i = 0; i < length; ++i) {
    output[i * 2] = digits[data[i] >> 4];
    output[i * 2 + 1] = digits[data[i] & 0x0f];
  }
  return output;
}

int nibble(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

bool unhex(const std::string &value, uint8_t *output, size_t length) {
  if (!output || value.size() != length * 2) return false;
  for (size_t i = 0; i < length; ++i) {
    const int high = nibble(value[i * 2]);
    const int low = nibble(value[i * 2 + 1]);
    if (high < 0 || low < 0) return false;
    output[i] = static_cast<uint8_t>((high << 4) | low);
  }
  return true;
}

bool hmac(const uint8_t *key, size_t keyLength,
          const uint8_t *data, size_t dataLength, uint8_t output[32]) {
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  return info && mbedtls_md_hmac(info, key, keyLength, data, dataLength, output) == 0;
}

bool constantTimeEqual(const uint8_t *left, const uint8_t *right, size_t length) {
  uint8_t difference = 0;
  for (size_t i = 0; i < length; ++i) difference |= left[i] ^ right[i];
  return difference == 0;
}

void append(std::string &target, const void *bytes, size_t length) {
  target.append(static_cast<const char *>(bytes), length);
}
}

void SecureSession::reset() {
  memset(secret_, 0, sizeof(secret_));
  memset(serverNonce_, 0, sizeof(serverNonce_));
  memset(key_, 0, sizeof(key_));
  memset(deviceId_, 0, sizeof(deviceId_));
  receiveCounter_ = 0;
  started_ = false;
  established_ = false;
}

bool SecureSession::begin(const uint8_t secret[SecretSize], const char *deviceId,
                          std::string &challengeReply) {
  reset();
  if (!secret || !deviceId || strlen(deviceId) != 12) return false;
  memcpy(secret_, secret, SecretSize);
  memcpy(deviceId_, deviceId, 12);
  esp_fill_random(serverNonce_, sizeof(serverNonce_));
  started_ = true;
  challengeReply = "secure challenge 1 " + std::string(deviceId_) + " " +
                   hex(serverNonce_, sizeof(serverNonce_));
  return true;
}

bool SecureSession::acceptHello(const std::string &line, std::string &serverReply) {
  if (!started_ || established_) return false;
  constexpr char Prefix[] = "secure hello ";
  if (line.rfind(Prefix, 0) != 0) return false;
  const size_t separator = line.find(' ', sizeof(Prefix) - 1);
  if (separator == std::string::npos) return false;
  const std::string clientNonceHex = line.substr(sizeof(Prefix) - 1,
                                                  separator - (sizeof(Prefix) - 1));
  const std::string proofHex = line.substr(separator + 1);
  uint8_t clientNonce[NonceSize];
  uint8_t suppliedProof[32];
  if (!unhex(clientNonceHex, clientNonce, sizeof(clientNonce)) ||
      !unhex(proofHex, suppliedProof, sizeof(suppliedProof))) return false;

  std::string transcript(ClientProofLabel);
  transcript += deviceId_;
  append(transcript, serverNonce_, sizeof(serverNonce_));
  append(transcript, clientNonce, sizeof(clientNonce));
  uint8_t expectedProof[32];
  if (!hmac(secret_, sizeof(secret_),
            reinterpret_cast<const uint8_t *>(transcript.data()), transcript.size(),
            expectedProof) || !constantTimeEqual(expectedProof, suppliedProof, 32)) {
    memset(clientNonce, 0, sizeof(clientNonce));
    return false;
  }

  uint8_t salt[NonceSize * 2];
  memcpy(salt, serverNonce_, NonceSize);
  memcpy(salt + NonceSize, clientNonce, NonceSize);
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (!info || mbedtls_hkdf(info, salt, sizeof(salt), secret_, sizeof(secret_),
                            reinterpret_cast<const uint8_t *>(KdfInfo),
                            strlen(KdfInfo), key_, sizeof(key_)) != 0) return false;

  transcript.replace(0, strlen(ClientProofLabel), ServerProofLabel);
  uint8_t serverProof[32];
  if (!hmac(secret_, sizeof(secret_),
            reinterpret_cast<const uint8_t *>(transcript.data()), transcript.size(),
            serverProof)) return false;
  serverReply = "secure ready " + hex(serverProof, sizeof(serverProof));
  receiveCounter_ = 0;
  established_ = true;
  memset(clientNonce, 0, sizeof(clientNonce));
  memset(expectedProof, 0, sizeof(expectedProof));
  return true;
}

bool SecureSession::decrypt(uint64_t counter, const uint8_t *ciphertext,
                            size_t length, const uint8_t tag[TagSize],
                            uint8_t *plaintext) {
  if (!established_ || counter <= receiveCounter_ || !ciphertext || !tag || !plaintext)
    return false;
  uint8_t nonce[12] = {'I', 'P', 'C', 1};
  for (size_t i = 0; i < 8; ++i)
    nonce[4 + i] = static_cast<uint8_t>(counter >> ((7 - i) * 8));
  mbedtls_gcm_context context;
  mbedtls_gcm_init(&context);
  int result = mbedtls_gcm_setkey(&context, MBEDTLS_CIPHER_ID_AES, key_, 256);
  if (result == 0) {
    result = mbedtls_gcm_auth_decrypt(
        &context, length, nonce, sizeof(nonce),
        reinterpret_cast<const uint8_t *>(deviceId_), 12,
        tag, TagSize, ciphertext, plaintext);
  }
  mbedtls_gcm_free(&context);
  if (result != 0) return false;
  receiveCounter_ = counter;
  return true;
}

bool SecureSession::decryptBinary(const uint8_t *record, size_t recordLength,
                                  uint8_t *plaintext, size_t plaintextCapacity,
                                  size_t &plaintextLength) {
  plaintextLength = 0;
  if (!record || recordLength < 1 + 8 + TagSize || record[0] != BinaryVersion)
    return false;
  const size_t cipherLength = recordLength - 1 - 8 - TagSize;
  if (cipherLength > plaintextCapacity) return false;
  uint64_t counter = 0;
  for (size_t i = 0; i < 8; ++i) counter = (counter << 8) | record[1 + i];
  if (!decrypt(counter, record + 9, cipherLength,
               record + 9 + cipherLength, plaintext)) return false;
  plaintextLength = cipherLength;
  return true;
}

bool SecureSession::decryptText(const std::string &line, std::string &plaintext) {
  constexpr char Prefix[] = "secure data ";
  if (line.rfind(Prefix, 0) != 0) return false;
  const size_t counterEnd = line.find(' ', sizeof(Prefix) - 1);
  const size_t cipherEnd = counterEnd == std::string::npos
                               ? std::string::npos : line.find(' ', counterEnd + 1);
  if (counterEnd == std::string::npos || cipherEnd == std::string::npos) return false;
  const std::string counterHex = line.substr(sizeof(Prefix) - 1,
                                              counterEnd - (sizeof(Prefix) - 1));
  if (counterHex.size() != 16) return false;
  uint64_t counter = 0;
  for (char value : counterHex) {
    const int part = nibble(value);
    if (part < 0) return false;
    counter = (counter << 4) | static_cast<uint64_t>(part);
  }
  const std::string cipherHex = line.substr(counterEnd + 1, cipherEnd - counterEnd - 1);
  const std::string tagHex = line.substr(cipherEnd + 1);
  if ((cipherHex.size() & 1) != 0 || tagHex.size() != TagSize * 2) return false;
  std::string ciphertext(cipherHex.size() / 2, '\0');
  std::string output(ciphertext.size(), '\0');
  uint8_t tag[TagSize];
  if (!unhex(cipherHex, reinterpret_cast<uint8_t *>(ciphertext.data()), ciphertext.size()) ||
      !unhex(tagHex, tag, sizeof(tag)) ||
      !decrypt(counter, reinterpret_cast<const uint8_t *>(ciphertext.data()),
               ciphertext.size(), tag, reinterpret_cast<uint8_t *>(output.data()))) return false;
  plaintext = std::move(output);
  return true;
}

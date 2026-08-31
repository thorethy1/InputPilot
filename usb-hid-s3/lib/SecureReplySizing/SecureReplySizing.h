#ifndef SECURE_REPLY_SIZING_H
#define SECURE_REPLY_SIZING_H

#include <stddef.h>

namespace SecureReplySizing {

constexpr size_t TextOverhead = 62;
constexpr size_t BinaryOverhead = 25;

constexpr size_t textRecordLength(size_t plaintextLength) {
  return TextOverhead + plaintextLength * 2;
}

constexpr size_t binaryRecordLength(size_t plaintextLength) {
  return BinaryOverhead + plaintextLength;
}

constexpr bool requiresBinary(size_t plaintextLength, size_t attPayloadBytes) {
  return textRecordLength(plaintextLength) > attPayloadBytes;
}

}  // namespace SecureReplySizing

#endif

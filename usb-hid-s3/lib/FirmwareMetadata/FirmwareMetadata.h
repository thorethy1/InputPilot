#ifndef FIRMWARE_METADATA_H
#define FIRMWARE_METADATA_H

#include <cstddef>
#include <cstdint>
#include <string>

struct FirmwareMetadataValue {
  std::string product;
  std::string board;
  std::string version;
  uint32_t protocol = 0;
  uint32_t otaSchema = 0;
};

class FirmwareMetadata {
 public:
  static bool parse(const uint8_t *data, size_t size, FirmwareMetadataValue &out);
  static bool compatible(const FirmwareMetadataValue &value, std::string &error);
};

#endif

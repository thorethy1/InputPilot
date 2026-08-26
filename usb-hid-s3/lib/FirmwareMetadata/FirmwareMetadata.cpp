#include "FirmwareMetadata.h"

#include <cstdlib>
#include <cstring>

#include "../../include/Config.h"

namespace {
const char *field(const std::string &metadata, const char *key, std::string &value) {
  const std::string needle = std::string(key) + "=";
  const size_t start = metadata.find(needle);
  if (start == std::string::npos) return nullptr;
  const size_t valueStart = start + needle.size();
  const size_t end = metadata.find(';', valueStart);
  value = metadata.substr(valueStart, end == std::string::npos ? std::string::npos : end - valueStart);
  return value.empty() ? nullptr : value.c_str();
}

bool number(const std::string &metadata, const char *key, uint32_t &value) {
  std::string raw;
  if (!field(metadata, key, raw)) return false;
  char *end = nullptr;
  const unsigned long parsed = std::strtoul(raw.c_str(), &end, 10);
  if (!end || *end || parsed > UINT32_MAX) return false;
  value = static_cast<uint32_t>(parsed);
  return true;
}
}  // namespace

bool FirmwareMetadata::parse(const uint8_t *data, size_t size, FirmwareMetadataValue &out) {
  static const char prefix[] = FW_METADATA_PREFIX;
  if (!data || size < sizeof(prefix)) return false;
  for (size_t offset = 0; offset + sizeof(prefix) <= size; ++offset) {
    if (memcmp(data + offset, prefix, sizeof(prefix) - 1) != 0) continue;
    const char *begin = reinterpret_cast<const char *>(data + offset + sizeof(prefix) - 1);
    const size_t remaining = size - offset - sizeof(prefix) + 1;
    const void *terminator = memchr(begin, '\0', remaining);
    if (!terminator) continue;
    const std::string metadata(begin, static_cast<const char *>(terminator) - begin);
    FirmwareMetadataValue candidate;
    if (field(metadata, "product", candidate.product) && field(metadata, "board", candidate.board) &&
        field(metadata, "version", candidate.version) && number(metadata, "protocol", candidate.protocol) &&
        number(metadata, "otaSchema", candidate.otaSchema)) {
      out = candidate;
      return true;
    }
  }
  return false;
}

bool FirmwareMetadata::compatible(const FirmwareMetadataValue &value, std::string &error) {
  if (value.product != FW_PRODUCT) { error = "incompatible_product"; return false; }
  if (value.board != FW_BOARD) { error = "incompatible_board"; return false; }
  if (value.protocol != OTA_PROTOCOL_VERSION) { error = "unsupported_protocol"; return false; }
  if (value.otaSchema > OTA_SCHEMA_VERSION) { error = "unsupported_ota_schema"; return false; }
  if (value.version.empty()) { error = "invalid_metadata"; return false; }
  return true;
}

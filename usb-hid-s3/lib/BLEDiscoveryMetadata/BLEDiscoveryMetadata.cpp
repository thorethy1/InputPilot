#include "BLEDiscoveryMetadata.h"

#include <cstdio>

#include "Config.h"
#include "ProtocolCapabilities.h"

std::string BLEDiscoveryMetadata::build(const char *deviceId,
                                        const char *deviceName) {
  char json[MaxGattValueBytes];
  const int written = snprintf(
      json, sizeof(json),
      "{\"product\":\"%s\",\"board\":\"%s\",\"deviceId\":\"%s\"," 
      "\"deviceName\":\"%s\",\"protocol\":%u,\"otaSchema\":%u," 
      "\"firmware\":\"%s\",\"trustRequired\":true,"
      "\"capabilities\":%s}",
      FW_PRODUCT, FW_BOARD, deviceId ? deviceId : "",
      deviceName ? deviceName : "", OTA_PROTOCOL_VERSION,
      OTA_SCHEMA_VERSION, FW_VERSION, ProtocolCapabilities::jsonArray());
  if (written < 0 || static_cast<size_t>(written) >= sizeof(json)) return {};
  return std::string(json, static_cast<size_t>(written));
}

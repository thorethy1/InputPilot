#ifndef BLE_DISCOVERY_METADATA_H
#define BLE_DISCOVERY_METADATA_H

#include <cstddef>
#include <string>

namespace BLEDiscoveryMetadata {

constexpr size_t MaxGattValueBytes = 512;

std::string build(const char *deviceId, const char *deviceName);

}  // namespace BLEDiscoveryMetadata

#endif

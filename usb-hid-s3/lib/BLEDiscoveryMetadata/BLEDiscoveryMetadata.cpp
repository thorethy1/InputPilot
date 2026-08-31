#include "BLEDiscoveryMetadata.h"

#include <cstdio>

#include "Config.h"

std::string BLEDiscoveryMetadata::build(const char *deviceId,
                                        const char *deviceName) {
  char json[MaxGattValueBytes];
  const int written = snprintf(
      json, sizeof(json),
      "{\"product\":\"%s\",\"board\":\"%s\",\"deviceId\":\"%s\"," 
      "\"deviceName\":\"%s\",\"protocol\":%u,\"otaSchema\":%u," 
      "\"firmware\":\"%s\",\"trustRequired\":true,"
      "\"capabilities\":[\"secure_protocol_v2\",\"ble_transport\"," 
      "\"wifi_transport\",\"secure_wifi_setup\",\"multiple_wifi\",\"secure_usb_identity\",\"usb_manufacturer\","
      "\"secure_ota\",\"secure_diagnostics\",\"mouse_move\",\"mouse_click\"," 
      "\"mouse_button_state\",\"mouse_scroll\",\"keyboard_type\"," 
      "\"keyboard_key\",\"keyboard_layout\",\"release_all\",\"protocol_v2\"]}",
      FW_PRODUCT, FW_BOARD, deviceId ? deviceId : "",
      deviceName ? deviceName : "", OTA_PROTOCOL_VERSION,
      OTA_SCHEMA_VERSION, FW_VERSION);
  if (written < 0 || static_cast<size_t>(written) >= sizeof(json)) return {};
  return std::string(json, static_cast<size_t>(written));
}

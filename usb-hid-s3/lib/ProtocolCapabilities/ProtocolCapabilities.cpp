#include "ProtocolCapabilities.h"

namespace ProtocolCapabilities {

const char *jsonArray() {
  return "[\"secure_protocol_v2\",\"protocol_core\","
         "\"ble_transport\",\"wifi_transport\",\"secure_wifi_setup\","
         "\"multiple_wifi\",\"secure_usb_identity\",\"usb_manufacturer\","
         "\"secure_ota\",\"secure_diagnostics\",\"mouse_move\","
         "\"mouse_click\",\"mouse_button_state\",\"mouse_scroll\","
         "\"keyboard_type\",\"keyboard_key\",\"keyboard_layout\","
         "\"release_all\",\"device_presets\"]";
}

const char *bleJsonArray() {
  // The GATT metadata value is capped at 512 bytes. Diagnostics are part of
  // secure protocol v2 and need no UI feature gate, so omit that one redundant
  // flag here while retaining it in the full Wi-Fi discovery contract.
  return "[\"secure_protocol_v2\",\"protocol_core\","
         "\"ble_transport\",\"wifi_transport\",\"secure_wifi_setup\","
         "\"multiple_wifi\",\"secure_usb_identity\",\"usb_manufacturer\","
         "\"secure_ota\",\"mouse_move\",\"mouse_click\","
         "\"mouse_button_state\",\"mouse_scroll\","
         "\"keyboard_type\",\"keyboard_key\",\"keyboard_layout\","
         "\"release_all\",\"device_presets\"]";
}

const char *radioModeJson(bool bleEnabled, bool wifiEnabled) {
  if (bleEnabled && wifiEnabled) return "\"wifi+ble\"";
  if (bleEnabled) return "\"ble\"";
  if (wifiEnabled) return "\"wifi\"";
  return "\"none\"";
}

}  // namespace ProtocolCapabilities

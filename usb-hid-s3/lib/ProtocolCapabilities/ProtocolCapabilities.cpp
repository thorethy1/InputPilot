#include "ProtocolCapabilities.h"

namespace ProtocolCapabilities {

const char *jsonArray() {
  return "[\"secure_protocol_v2\",\"protocol_core\","
         "\"ble_transport\",\"wifi_transport\",\"secure_wifi_setup\","
         "\"multiple_wifi\",\"secure_usb_identity\",\"usb_manufacturer\","
         "\"secure_ota\",\"secure_diagnostics\",\"mouse_move\","
         "\"mouse_click\",\"mouse_button_state\",\"mouse_scroll\","
         "\"keyboard_type\",\"keyboard_key\",\"keyboard_layout\","
         "\"release_all\"]";
}

}  // namespace ProtocolCapabilities

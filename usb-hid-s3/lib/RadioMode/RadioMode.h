#ifndef RADIO_MODE_H
#define RADIO_MODE_H

// Pure, Arduino-free radio selection. Wi-Fi and BLE may coexist.
// The actual WiFi/BLE stack wiring lands in Phase 3; this is the shared type +
// string mapping used by config, serial commands, and status.

#include <string>

enum class RadioMode {
  None,  // no radio active
  Wifi,  // WiFi STA active, BLE off
  Ble,   // BLE active, WiFi off
  WifiBle, // WiFi and BLE active with ESP32 coexistence
};

const char *radioModeToString(RadioMode m);

// Parse "none"/"off", "wifi", "ble" (case-insensitive). Returns false if
// unrecognized; *out is left unchanged.
bool radioModeFromString(const std::string &s, RadioMode &out);

#endif // RADIO_MODE_H

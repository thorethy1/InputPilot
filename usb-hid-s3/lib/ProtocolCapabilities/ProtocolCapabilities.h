#ifndef INPUTPILOT_PROTOCOL_CAPABILITIES_H
#define INPUTPILOT_PROTOCOL_CAPABILITIES_H

// One capability contract for every discovery transport. Capabilities describe
// features and transports supported by the firmware/device. They do not imply
// that a transport is enabled in the current radio mode.
namespace ProtocolCapabilities {
const char *jsonArray();
const char *radioModeJson(bool bleEnabled, bool wifiEnabled);
}

#endif  // INPUTPILOT_PROTOCOL_CAPABILITIES_H

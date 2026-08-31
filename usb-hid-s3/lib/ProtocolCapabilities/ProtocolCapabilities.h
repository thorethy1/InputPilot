#ifndef INPUTPILOT_PROTOCOL_CAPABILITIES_H
#define INPUTPILOT_PROTOCOL_CAPABILITIES_H

// One capability contract for every discovery transport. Capabilities describe
// the InputPilot protocol core, not which endpoint happened to report them.
namespace ProtocolCapabilities {
const char *jsonArray();
}

#endif  // INPUTPILOT_PROTOCOL_CAPABILITIES_H

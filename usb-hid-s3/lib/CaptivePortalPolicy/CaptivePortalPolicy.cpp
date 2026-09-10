#include "CaptivePortalPolicy.h"

#include <sys/socket.h>

namespace CaptivePortalPolicy {

bool parseAddressFamily(const std::string &value, AddressFamily &family) {
  if (value == "AUTO") {
    family = AddressFamily::Auto;
    return true;
  }
  if (value == "IPV4") {
    family = AddressFamily::IPv4;
    return true;
  }
  return false;
}

int resolverFamily(AddressFamily family) {
  return family == AddressFamily::IPv4 ? AF_INET : AF_UNSPEC;
}

const char *addressFamilyName(AddressFamily family) {
  return family == AddressFamily::IPv4 ? "ipv4" : "auto";
}

bool blocksWireGuard(GateState state) {
  return state == GateState::Waiting || state == GateState::Running ||
         state == GateState::Failed;
}

void Gate::associate(const std::string &ssid, bool enabledScript) {
  ssid_ = ssid;
  state_ = enabledScript ? GateState::Waiting : GateState::NotRequired;
}

void Gate::disconnect() {
  ssid_.clear();
  state_ = GateState::NotRequired;
}

void Gate::start(const std::string &ssid) {
  ssid_ = ssid;
  state_ = GateState::Running;
}

void Gate::finish(const std::string &ssid, GateState result) {
  if (ssid != ssid_ || (result != GateState::Success &&
                        result != GateState::AlreadyConnected &&
                        result != GateState::Failed)) {
    return;
  }
  state_ = result;
}

bool Gate::blocksWireGuard() const {
  return CaptivePortalPolicy::blocksWireGuard(state_);
}

}  // namespace CaptivePortalPolicy

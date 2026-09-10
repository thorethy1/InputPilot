#ifndef INPUTPILOT_CAPTIVE_PORTAL_POLICY_H
#define INPUTPILOT_CAPTIVE_PORTAL_POLICY_H

#include <string>

namespace CaptivePortalPolicy {

enum class AddressFamily { Auto, IPv4 };

bool parseAddressFamily(const std::string &value, AddressFamily &family);
int resolverFamily(AddressFamily family);
const char *addressFamilyName(AddressFamily family);

enum class GateState {
  NotRequired,
  Waiting,
  Running,
  Success,
  AlreadyConnected,
  Failed,
};

bool blocksWireGuard(GateState state);

// Association-aware state holder used by the firmware and host-side tests.
// Results from an old SSID are deliberately ignored after an association
// change, so one network can never release another network's gate.
class Gate {
 public:
  void associate(const std::string &ssid, bool enabledScript);
  void disconnect();
  void start(const std::string &ssid);
  void finish(const std::string &ssid, GateState result);

  GateState state() const { return state_; }
  bool blocksWireGuard() const;
  const std::string &ssid() const { return ssid_; }

 private:
  std::string ssid_;
  GateState state_ = GateState::NotRequired;
};

}  // namespace CaptivePortalPolicy

#endif  // INPUTPILOT_CAPTIVE_PORTAL_POLICY_H

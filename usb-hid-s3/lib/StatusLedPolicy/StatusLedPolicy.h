#ifndef STATUS_LED_POLICY_H
#define STATUS_LED_POLICY_H

#include <cstdint>

namespace StatusLedPolicy {

enum class State {
  Ota,
  FallbackAp,
  KeepAwake,
  ControllerConnected,
  Ready,
  Unavailable,
};

struct Inputs {
  bool otaActive = false;
  bool fallbackApActive = false;
  bool keepAwakeActive = false;
  bool controllerConnected = false;
  bool controlRadioReady = false;
};

inline State resolve(const Inputs &inputs, uint32_t nowMs = 0) {
  if (inputs.otaActive) return State::Ota;
  if (inputs.fallbackApActive && nowMs % 4000 < 180) return State::FallbackAp;
  if (inputs.keepAwakeActive) return State::KeepAwake;
  if (inputs.controllerConnected) return State::ControllerConnected;
  if (inputs.controlRadioReady) return State::Ready;
  return State::Unavailable;
}

}  // namespace StatusLedPolicy

#endif  // STATUS_LED_POLICY_H

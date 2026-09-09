#ifndef WIFI_FALLBACK_POLICY_H
#define WIFI_FALLBACK_POLICY_H

#include <stddef.h>

namespace WifiFallbackPolicy {

enum class RetryDecision {
  Wait,
  DeferForActiveClient,
  RetryStation,
};

inline const char *connectionState(bool stationConnecting,
                                   bool stationConnected, bool softApActive,
                                   bool wifiEnabled, bool fallbackWaiting) {
  // AP+STA is still a station handoff in progress. Consumers must not cache
  // the temporary AP gateway as the final station endpoint.
  if (stationConnecting) return "connecting";
  if (stationConnected) return "connected";
  if (softApActive) return "soft_ap";
  if (wifiEnabled && !fallbackWaiting) return "connecting";
  return "disconnected";
}

inline RetryDecision decide(size_t credentialCount, bool retryIntervalElapsed,
                            size_t softApClientCount) {
  if (credentialCount == 0 || !retryIntervalElapsed) return RetryDecision::Wait;
  if (softApClientCount > 0) return RetryDecision::DeferForActiveClient;
  return RetryDecision::RetryStation;
}

}  // namespace WifiFallbackPolicy

#endif  // WIFI_FALLBACK_POLICY_H

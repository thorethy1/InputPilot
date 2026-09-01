#ifndef WIFI_FALLBACK_POLICY_H
#define WIFI_FALLBACK_POLICY_H

#include <stddef.h>

namespace WifiFallbackPolicy {

enum class RetryDecision {
  Wait,
  DeferForActiveClient,
  RetryStation,
};

inline RetryDecision decide(size_t credentialCount, bool retryIntervalElapsed,
                            size_t softApClientCount) {
  if (credentialCount == 0 || !retryIntervalElapsed) return RetryDecision::Wait;
  if (softApClientCount > 0) return RetryDecision::DeferForActiveClient;
  return RetryDecision::RetryStation;
}

}  // namespace WifiFallbackPolicy

#endif  // WIFI_FALLBACK_POLICY_H

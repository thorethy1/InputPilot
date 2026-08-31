#ifndef BLE_SESSION_OWNERSHIP_H
#define BLE_SESSION_OWNERSHIP_H

#include <cstdint>

// Tracks the single BLE connection that owns the BLE transport session.
// This class deliberately has no Arduino/NimBLE dependencies so its timeout
// and connection-race behaviour can be covered by host tests.
class BLESessionOwnership {
 public:
  static constexpr uint16_t NoOwner = UINT16_MAX;

  enum class ClaimResult : uint8_t {
    Claimed,
    AlreadyOwner,
    Rejected,
  };

  explicit BLESessionOwnership(uint32_t authenticationTimeoutMs)
      : authenticationTimeoutMs_(authenticationTimeoutMs) {}

  ClaimResult claim(uint16_t connectionHandle, uint32_t nowMs) {
    (void)nowMs;
    if (owner_ == connectionHandle) return ClaimResult::AlreadyOwner;
    if (owner_ != NoOwner) return ClaimResult::Rejected;
    owner_ = connectionHandle;
    // A BLE link is not an authentication attempt. GATT discovery can be
    // delayed by radio coexistence, especially while STA is scanning. Start
    // the bounded authentication window only after Secure Protocol traffic
    // actually reaches the protocol loop.
    authenticationDeadlineMs_ = 0;
    return ClaimResult::Claimed;
  }

  void authenticationStarted(uint16_t connectionHandle, uint32_t nowMs) {
    if (owner_ == connectionHandle && authenticationDeadlineMs_ == 0)
      authenticationDeadlineMs_ = nowMs + authenticationTimeoutMs_;
  }

  bool release(uint16_t connectionHandle) {
    if (owner_ != connectionHandle) return false;
    clear();
    return true;
  }

  void restartAuthentication(uint16_t connectionHandle, uint32_t nowMs) {
    if (owner_ == connectionHandle)
      authenticationDeadlineMs_ = nowMs + authenticationTimeoutMs_;
  }

  void authenticated(uint16_t connectionHandle) {
    if (owner_ == connectionHandle) authenticationDeadlineMs_ = 0;
  }

  void pauseAuthenticationTimeout(uint16_t connectionHandle) {
    if (owner_ == connectionHandle) authenticationDeadlineMs_ = 0;
  }

  bool authenticationExpired(uint32_t nowMs, bool isAuthenticated) const {
    return owner_ != NoOwner && !isAuthenticated &&
           authenticationDeadlineMs_ != 0 &&
           static_cast<int32_t>(nowMs - authenticationDeadlineMs_) >= 0;
  }

  bool owns(uint16_t connectionHandle) const {
    return owner_ != NoOwner && owner_ == connectionHandle;
  }

  bool connected() const { return owner_ != NoOwner; }
  uint16_t owner() const { return owner_; }

  void clear() {
    owner_ = NoOwner;
    authenticationDeadlineMs_ = 0;
  }

 private:
  const uint32_t authenticationTimeoutMs_;
  uint16_t owner_ = NoOwner;
  uint32_t authenticationDeadlineMs_ = 0;
};

#endif  // BLE_SESSION_OWNERSHIP_H

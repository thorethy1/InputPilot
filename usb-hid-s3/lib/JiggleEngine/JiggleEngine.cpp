#include "JiggleEngine.h"

JiggleEngine::JiggleEngine(int maxDelta, uint32_t intervalMs, uint32_t seed)
    : maxDelta_(maxDelta < 1 ? 1 : maxDelta),
      intervalMs_(intervalMs),
      rngState_(seed ? seed : 0x12345678u) {}

uint32_t JiggleEngine::rand32() {
  // xorshift32 - deterministic, no libc rand().
  uint32_t x = rngState_;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  rngState_ = x;
  return x;
}

int JiggleEngine::nextDelta() {
  const int span = 2 * maxDelta_ + 1;         // [-max, max]
  return static_cast<int>(rand32() % static_cast<uint32_t>(span)) - maxDelta_;
}

void JiggleEngine::setEnabled(bool enabled) {
  enabled_ = enabled;
  anchored_ = false;  // re-anchor on next update so a burst fires promptly
}

void JiggleEngine::reset(uint32_t nowMs) {
  lastFireMs_ = nowMs;
  anchored_ = true;
}

bool JiggleEngine::update(uint32_t nowMs, int &dx, int &dy) {
  if (!enabled_) return false;

  if (!anchored_) {
    // First tick after enable: fire immediately so movement is observable.
    lastFireMs_ = nowMs - intervalMs_;
    anchored_ = true;
  }

  if ((uint32_t)(nowMs - lastFireMs_) < intervalMs_) return false;

  lastFireMs_ = nowMs;
  dx = nextDelta();
  dy = nextDelta();
  if (dx == 0 && dy == 0) dx = maxDelta_;  // guarantee observable motion
  return true;
}

void JiggleEngine::setClickEnabled(bool enabled) {
  clickEnabled_ = enabled;
  clickAnchored_ = false;
}

bool JiggleEngine::updateClick(uint32_t nowMs) {
  if (!clickEnabled_) return false;
  if (!clickAnchored_) {
    // Unlike pointer movement, never click immediately when enabled.
    lastClickMs_ = nowMs;
    clickAnchored_ = true;
    return false;
  }
  if ((uint32_t)(nowMs - lastClickMs_) < clickIntervalMs_) return false;
  lastClickMs_ = nowMs;
  return true;
}

uint32_t JiggleEngine::msUntilNext(uint32_t nowMs) const {
  if (!enabled_ || !anchored_) return 0;
  const uint32_t elapsed = (uint32_t)(nowMs - lastFireMs_);
  if (elapsed >= intervalMs_) return 0;
  return intervalMs_ - elapsed;
}

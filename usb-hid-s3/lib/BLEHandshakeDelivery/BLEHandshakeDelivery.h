#ifndef BLE_HANDSHAKE_DELIVERY_H
#define BLE_HANDSHAKE_DELIVERY_H

#include <algorithm>
#include <cstdint>
#include <string>

// Only handshake replies are fragmented. Encrypted records retain their
// existing framing and must never be split into independent notifications.
class BLEHandshakeDelivery {
 public:
  void queue(const std::string &reply, uint32_t generation, uint32_t now) {
    reply_ = reply;
    offset_ = 0;
    generation_ = generation;
    started_ = now;
    lastAttempt_ = now - 20;
  }

  template <typename Sender>
  void flush(uint32_t generation, bool connected, uint16_t mtu,
             uint32_t now, Sender send) {
    if (reply_.empty()) return;
    if (!connected || generation != generation_ || now - started_ >= 15000) {
      reply_.clear();
      return;
    }
    if (mtu <= 3 || now - lastAttempt_ < 20) return;
    lastAttempt_ = now;
    const size_t length = std::min(reply_.size() - offset_, size_t(mtu - 3));
    if (!send(reinterpret_cast<const uint8_t *>(reply_.data() + offset_), length)) return;
    offset_ += length;
    if (offset_ == reply_.size()) reply_.clear();
  }

 private:
  std::string reply_;
  size_t offset_ = 0;
  uint32_t generation_ = 0, started_ = 0, lastAttempt_ = 0;
};

#endif

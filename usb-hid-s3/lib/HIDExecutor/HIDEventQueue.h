#ifndef HID_EVENT_QUEUE_H
#define HID_EVENT_QUEUE_H

#include <cstddef>
#include <cstdint>
#include <cstring>

enum class HIDEventType : uint8_t {
  MouseMove, Click, ButtonDown, ButtonUp, TypeText, KeyboardReport, ReleaseAll
};

struct HIDEvent {
  HIDEventType type = HIDEventType::MouseMove;
  int32_t dx = 0;
  int32_t dy = 0;
  int32_t wheel = 0;
  uint8_t button = 0;
  uint8_t modifier = 0;
  uint8_t keycode = 0;
  uint32_t sequence = 0;
  char text[256]{};

  static HIDEvent move(int dx, int dy, int wheel = 0) {
    HIDEvent e; e.type = HIDEventType::MouseMove; e.dx = dx; e.dy = dy; e.wheel = wheel; return e;
  }
  static HIDEvent releaseAll() { HIDEvent e; e.type = HIDEventType::ReleaseAll; return e; }
  bool critical() const {
    return type == HIDEventType::ButtonDown || type == HIDEventType::ButtonUp ||
           type == HIDEventType::KeyboardReport || type == HIDEventType::ReleaseAll;
  }
};

class HIDEventQueue {
 public:
  static constexpr size_t Capacity = 32;
  static constexpr size_t CriticalReserve = 6;

  bool push(HIDEvent event) {
    if (event.type == HIDEventType::ReleaseAll) {
      clear();
      return append(event);
    }
    if (event.type == HIDEventType::MouseMove && count_) {
      HIDEvent &last = entries_[(write_ + Capacity - 1) % Capacity];
      if (last.type == HIDEventType::MouseMove) {
        last.dx += event.dx; last.dy += event.dy; last.wheel += event.wheel;
        last.sequence = event.sequence;
        return true;
      }
    }
    if (!event.critical() && count_ >= Capacity - CriticalReserve) return false;
    if (count_ == Capacity && event.critical()) {
      if (!removeOldestMove()) return false;
    }
    return append(event);
  }

  bool pop(HIDEvent &out) {
    if (!count_) return false;
    out = entries_[read_]; read_ = (read_ + 1) % Capacity; --count_; return true;
  }
  void clear() { read_ = write_ = count_ = 0; }
  size_t size() const { return count_; }

 private:
  bool append(const HIDEvent &event) {
    if (count_ == Capacity) return false;
    entries_[write_] = event; write_ = (write_ + 1) % Capacity; ++count_; return true;
  }
  bool removeOldestMove() {
    for (size_t logical = 0; logical < count_; ++logical) {
      if (entries_[(read_ + logical) % Capacity].type != HIDEventType::MouseMove) continue;
      for (size_t next = logical; next + 1 < count_; ++next) {
        entries_[(read_ + next) % Capacity] = entries_[(read_ + next + 1) % Capacity];
      }
      write_ = (write_ + Capacity - 1) % Capacity;
      --count_;
      return true;
    }
    return false;
  }

  HIDEvent entries_[Capacity]{};
  size_t read_ = 0, write_ = 0, count_ = 0;
};

#endif

#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>

// Collect a bounded page without repeatedly reallocating a contiguous String
// while TLS still holds its record buffers and cryptographic state.
class CaptiveResponseBuffer {
 public:
  static constexpr size_t BlockBytes = 512;
  static constexpr size_t MaxBytes = 32768;
  using Allocator = uint8_t *(*)(size_t);
  explicit CaptiveResponseBuffer(size_t limit, Allocator allocator = allocate)
      : limit_(std::min(limit, MaxBytes)), allocator_(allocator) {}

  size_t append(const uint8_t *data, size_t length) {
    if (lowMemory_ || overflow_) return 0;
    const size_t accepted = std::min(length, limit_ - size_);
    size_t copied = 0;
    while (copied < accepted) {
      const size_t index = size_ / BlockBytes;
      const size_t offset = size_ % BlockBytes;
      if (!blocks_[index]) {
        blocks_[index].reset(allocator_(BlockBytes));
        if (!blocks_[index]) {
          lowMemory_ = true;
          return copied;
        }
      }
      const size_t count = std::min(accepted - copied, BlockBytes - offset);
      std::memcpy(blocks_[index].get() + offset, data + copied, count);
      copied += count;
      size_ += count;
    }
    overflow_ = accepted != length;
    return copied;
  }

  size_t size() const { return size_; }
  bool lowMemory() const { return lowMemory_; }
  bool overflowed() const { return overflow_; }
  const uint8_t *block(size_t index) const { return blocks_[index].get(); }

 private:
  static uint8_t *allocate(size_t length) { return new (std::nothrow) uint8_t[length]; }
  std::array<std::unique_ptr<uint8_t[]>, MaxBytes / BlockBytes> blocks_{};
  size_t limit_;
  Allocator allocator_;
  size_t size_ = 0;
  bool lowMemory_ = false;
  bool overflow_ = false;
};

#ifndef FIRMWARE_LOG_BUFFER_H
#define FIRMWARE_LOG_BUFFER_H

#include <cstddef>
#include <cstdint>
#include <cstring>

struct FirmwareLogEntry {
  uint32_t sequence = 0;
  char line[160]{};
};

class FirmwareLogBuffer {
 public:
  static constexpr size_t Capacity = 64;
  static constexpr size_t LineBytes = sizeof(FirmwareLogEntry::line);
  static constexpr size_t StorageBytes = Capacity * LineBytes;
  static constexpr size_t TotalEntryBytes = Capacity * sizeof(FirmwareLogEntry);

  uint32_t append(const char *line) {
    const uint32_t sequence = ++nextSequence_;
    FirmwareLogEntry &entry = entries_[writeIndex_];
    entry.sequence = sequence;
    std::strncpy(entry.line, line ? line : "", LineBytes - 1);
    entry.line[LineBytes - 1] = '\0';
    writeIndex_ = (writeIndex_ + 1) % Capacity;
    if (count_ < Capacity) ++count_;
    return sequence;
  }

  size_t copySince(uint32_t cursor, FirmwareLogEntry *out, size_t maxEntries) const {
    if (!out || !maxEntries) return 0;
    size_t copied = 0;
    const size_t oldest = (writeIndex_ + Capacity - count_) % Capacity;
    for (size_t i = 0; i < count_ && copied < maxEntries; ++i) {
      const FirmwareLogEntry &entry = entries_[(oldest + i) % Capacity];
      if (entry.sequence > cursor) out[copied++] = entry;
    }
    return copied;
  }

  void clear() { count_ = 0; writeIndex_ = 0; }
  size_t size() const { return count_; }
  uint32_t latestSequence() const { return nextSequence_; }

 private:
  FirmwareLogEntry entries_[Capacity]{};
  size_t writeIndex_ = 0;
  size_t count_ = 0;
  uint32_t nextSequence_ = 0;
};

#endif

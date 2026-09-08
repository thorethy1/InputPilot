#include "PresetEngine.h"

#include <cstring>

uint32_t PresetEngine::checksum(const uint8_t *data, size_t length) {
  uint32_t value = 2166136261u;
  for (size_t i = 0; i < length; ++i) value = (value ^ data[i]) * 16777619u;
  return value;
}

uint32_t PresetEngine::readU32(const uint8_t *data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

PresetEngine::Result PresetEngine::begin(uint64_t token, size_t size,
                                          uint32_t checksumValue) {
  if (token == 0 || size == 0) return Result::Invalid;
  if (size > MaxProgramBytes) return Result::TooLarge;
  if (state_ == State::Running || state_ == State::Completing) return Result::Busy;
  // BEGIN is idempotent so a lost acknowledgement can be retried and an upload
  // can resume at the byte offset reported by the device.
  if (state_ == State::Uploading && token_ == token && program_.size() == size &&
      expectedChecksum_ == checksumValue) return Result::Ok;
  if (state_ == State::Uploading) return Result::Busy;
  token_ = token;
  expectedChecksum_ = checksumValue;
  program_.assign(size, 0);
  totalSize_ = size;
  received_ = 0;
  position_ = 0;
  instructionPending_ = false;
  delayActive_ = false;
  state_ = State::Uploading;
  return Result::Ok;
}

PresetEngine::Result PresetEngine::write(uint64_t token, size_t offset,
                                          const uint8_t *data, size_t length) {
  if (state_ != State::Uploading || token != token_) return Result::WrongToken;
  if (!data || length == 0 || offset > program_.size() ||
      length > program_.size() - offset) return Result::Invalid;
  // DATA is also idempotent: accept a retransmitted, already committed chunk
  // only if every byte is identical.
  if (offset < received_) {
    if (offset + length <= received_ &&
        memcmp(program_.data() + offset, data, length) == 0) return Result::Ok;
    return Result::WrongOffset;
  }
  if (offset != received_) return Result::WrongOffset;
  memcpy(program_.data() + offset, data, length);
  received_ += length;
  return Result::Ok;
}

bool PresetEngine::validProgram() const {
  if (program_.empty()) return false;
  size_t cursor = 0;
  while (cursor < program_.size()) {
    const uint8_t opcode = program_[cursor++];
    if (opcode == ReportOpcode) {
      if (program_.size() - cursor < 2) return false;
      cursor += 2;
    } else if (opcode == DelayOpcode) {
      if (program_.size() - cursor < 4) return false;
      // Individual delays are bounded, while any number of them can make a
      // preset hours long without risking millis() wrap comparisons.
      if (readU32(program_.data() + cursor) > 60000) return false;
      cursor += 4;
    } else if (opcode == MouseClickOpcode) {
      if (program_.size() - cursor < 1 || program_[cursor] > 2) return false;
      cursor += 1;
    } else {
      return false;
    }
  }
  return true;
}

PresetEngine::Result PresetEngine::run(uint64_t token) {
  if ((state_ == State::Running || state_ == State::Completing) && token == token_)
    return Result::Ok;
  if (state_ != State::Uploading || token != token_) return Result::WrongToken;
  if (received_ != program_.size() || !validProgram()) {
    state_ = State::Failed;
    return Result::Invalid;
  }
  if (checksum(program_.data(), program_.size()) != expectedChecksum_) {
    state_ = State::Failed;
    return Result::ChecksumMismatch;
  }
  position_ = 0;
  instructionPending_ = false;
  delayActive_ = false;
  state_ = State::Running;
  return Result::Ok;
}

bool PresetEngine::abort(uint64_t token) {
  if (token != 0 && token != token_) return false;
  if (state_ != State::Uploading && state_ != State::Running &&
      state_ != State::Completing) return false;
  state_ = State::Cancelled;
  instructionPending_ = false;
  delayActive_ = false;
  std::vector<uint8_t>().swap(program_);
  return true;
}

bool PresetEngine::poll(uint32_t nowMs, Instruction &instruction) {
  if (state_ != State::Running || instructionPending_) return false;
  if (delayActive_) {
    if (static_cast<int32_t>(nowMs - delayUntilMs_) < 0) return false;
    delayActive_ = false;
  }
  while (position_ < program_.size()) {
    const uint8_t opcode = program_[position_++];
    if (opcode == DelayOpcode) {
      const uint32_t duration = readU32(program_.data() + position_);
      position_ += 4;
      if (duration == 0) continue;
      delayUntilMs_ = nowMs + duration;
      delayActive_ = true;
      return false;
    }
    if (opcode == MouseClickOpcode) {
      instruction.type = InstructionType::MouseClick;
      instruction.mouseButton = program_[position_++];
      instructionPending_ = true;
      return true;
    }
    instruction.type = InstructionType::KeyboardReport;
    instruction.modifier = program_[position_++];
    instruction.keycode = program_[position_++];
    instructionPending_ = true;
    return true;
  }
  state_ = State::Completing;
  instruction.type = InstructionType::ReleaseAll;
  instructionPending_ = true;
  return true;
}

void PresetEngine::instructionCompleted() {
  if (!instructionPending_) return;
  instructionPending_ = false;
  if (state_ == State::Completing) {
    state_ = State::Completed;
    std::vector<uint8_t>().swap(program_);
  }
}

const char *PresetEngine::stateName() const {
  switch (state_) {
    case State::Uploading: return "uploading";
    case State::Running: return "running";
    case State::Completing: return "running";
    case State::Completed: return "completed";
    case State::Cancelled: return "cancelled";
    case State::Failed: return "failed";
    case State::Idle: default: return "idle";
  }
}

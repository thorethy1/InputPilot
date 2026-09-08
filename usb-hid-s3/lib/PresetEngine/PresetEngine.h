#ifndef INPUTPILOT_PRESET_ENGINE_H
#define INPUTPILOT_PRESET_ENGINE_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// Receives a complete, checksummed keyboard program before executing it.  The
// transport is only needed while uploading; poll() drives the accepted program
// from the main firmware loop afterwards.
class PresetEngine {
 public:
  static constexpr size_t MaxProgramBytes = 64 * 1024;
  static constexpr uint8_t ReportOpcode = 0x01;
  static constexpr uint8_t DelayOpcode = 0x02;
  static constexpr uint8_t MouseClickOpcode = 0x03;

  enum class State { Idle, Uploading, Running, Completing, Completed, Cancelled, Failed };
  enum class Result { Ok, Busy, Invalid, WrongToken, WrongOffset, TooLarge, ChecksumMismatch };
  enum class InstructionType { KeyboardReport, MouseClick, ReleaseAll };

  struct Instruction {
    InstructionType type = InstructionType::ReleaseAll;
    uint8_t modifier = 0;
    uint8_t keycode = 0;
    uint8_t mouseButton = 0;
  };

  Result begin(uint64_t token, size_t size, uint32_t checksum);
  Result write(uint64_t token, size_t offset, const uint8_t *data, size_t length);
  Result run(uint64_t token);
  bool abort(uint64_t token);

  // Returns at most one HID instruction. Delays are consumed internally with
  // wrap-safe millis() arithmetic; execution never blocks the firmware loop.
  bool poll(uint32_t nowMs, Instruction &instruction);
  void instructionCompleted();

  State state() const { return state_; }
  uint64_t token() const { return token_; }
  size_t received() const { return received_; }
  size_t size() const { return totalSize_; }
  size_t position() const { return position_; }
  const char *stateName() const;

  static uint32_t checksum(const uint8_t *data, size_t length);

 private:
  bool validProgram() const;
  static uint32_t readU32(const uint8_t *data);

  State state_ = State::Idle;
  uint64_t token_ = 0;
  uint32_t expectedChecksum_ = 0;
  std::vector<uint8_t> program_;
  size_t totalSize_ = 0;
  size_t received_ = 0;
  size_t position_ = 0;
  bool instructionPending_ = false;
  bool delayActive_ = false;
  uint32_t delayUntilMs_ = 0;
};

#endif  // INPUTPILOT_PRESET_ENGINE_H

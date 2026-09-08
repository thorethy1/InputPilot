#include <unity.h>

#include "PresetEngine.h"

#include <vector>

void setUp() {}
void tearDown() {}

static void appendDelay(std::vector<uint8_t> &program, uint32_t milliseconds) {
  program.push_back(PresetEngine::DelayOpcode);
  program.push_back(static_cast<uint8_t>(milliseconds));
  program.push_back(static_cast<uint8_t>(milliseconds >> 8));
  program.push_back(static_cast<uint8_t>(milliseconds >> 16));
  program.push_back(static_cast<uint8_t>(milliseconds >> 24));
}

void test_upload_is_ordered_idempotent_and_checksummed() {
  const uint8_t program[] = {PresetEngine::ReportOpcode, 2, 4};
  const uint32_t checksum = PresetEngine::checksum(program, sizeof(program));
  PresetEngine engine;
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.begin(0x1234, sizeof(program), checksum)));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Busy), int(engine.begin(0x5678, sizeof(program), checksum)));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::WrongOffset), int(engine.write(0x1234, 1, program, 1)));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.write(0x1234, 0, program, 2)));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.write(0x1234, 0, program, 2)));
  TEST_ASSERT_EQUAL(2, engine.received());
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.write(0x1234, 2, program + 2, 1)));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.run(0x1234)));
}

void test_bad_checksum_never_executes() {
  const uint8_t program[] = {PresetEngine::ReportOpcode, 0, 40};
  PresetEngine engine;
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.begin(7, sizeof(program), 0)));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.write(7, 0, program, sizeof(program))));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::ChecksumMismatch), int(engine.run(7)));
  PresetEngine::Instruction instruction;
  TEST_ASSERT_FALSE(engine.poll(0, instruction));
}

void test_ten_minute_program_runs_without_blocking_or_transport() {
  std::vector<uint8_t> program;
  for (int i = 0; i < 10; ++i) appendDelay(program, 60000);
  program.insert(program.end(), {PresetEngine::ReportOpcode, 0, 40});
  PresetEngine engine;
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.begin(9, program.size(), PresetEngine::checksum(program.data(), program.size()))));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.write(9, 0, program.data(), program.size())));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.run(9)));
  PresetEngine::Instruction instruction;
  TEST_ASSERT_FALSE(engine.poll(0, instruction));
  for (uint32_t minute = 1; minute < 10; ++minute)
    TEST_ASSERT_FALSE(engine.poll(minute * 60000, instruction));
  TEST_ASSERT_TRUE(engine.poll(600000, instruction));
  TEST_ASSERT_EQUAL(int(PresetEngine::InstructionType::KeyboardReport), int(instruction.type));
  TEST_ASSERT_EQUAL(40, instruction.keycode);
  engine.instructionCompleted();
  TEST_ASSERT_TRUE(engine.poll(600001, instruction));
  TEST_ASSERT_EQUAL(int(PresetEngine::InstructionType::ReleaseAll), int(instruction.type));
  engine.instructionCompleted();
  TEST_ASSERT_EQUAL(int(PresetEngine::State::Completed), int(engine.state()));
}

void test_abort_during_delay_stops_and_allows_no_more_reports() {
  std::vector<uint8_t> program;
  appendDelay(program, 60000);
  program.insert(program.end(), {PresetEngine::ReportOpcode, 0, 4});
  PresetEngine engine;
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.begin(11, program.size(), PresetEngine::checksum(program.data(), program.size()))));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.write(11, 0, program.data(), program.size())));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.run(11)));
  PresetEngine::Instruction instruction;
  TEST_ASSERT_FALSE(engine.poll(0, instruction));
  TEST_ASSERT_TRUE(engine.abort(11));
  TEST_ASSERT_FALSE(engine.poll(60000, instruction));
  TEST_ASSERT_EQUAL(int(PresetEngine::State::Cancelled), int(engine.state()));
}

void test_mouse_click_instruction_is_validated_and_emitted() {
  const uint8_t program[] = {PresetEngine::MouseClickOpcode, 1};
  PresetEngine engine;
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok),
                    int(engine.begin(12, sizeof(program),
                                     PresetEngine::checksum(program, sizeof(program)))));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok),
                    int(engine.write(12, 0, program, sizeof(program))));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok), int(engine.run(12)));
  PresetEngine::Instruction instruction;
  TEST_ASSERT_TRUE(engine.poll(0, instruction));
  TEST_ASSERT_EQUAL(int(PresetEngine::InstructionType::MouseClick),
                    int(instruction.type));
  TEST_ASSERT_EQUAL_UINT8(1, instruction.mouseButton);
}

void test_mouse_click_rejects_unknown_button() {
  const uint8_t program[] = {PresetEngine::MouseClickOpcode, 3};
  PresetEngine engine;
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok),
                    int(engine.begin(13, sizeof(program),
                                     PresetEngine::checksum(program, sizeof(program)))));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Ok),
                    int(engine.write(13, 0, program, sizeof(program))));
  TEST_ASSERT_EQUAL(int(PresetEngine::Result::Invalid), int(engine.run(13)));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_upload_is_ordered_idempotent_and_checksummed);
  RUN_TEST(test_bad_checksum_never_executes);
  RUN_TEST(test_ten_minute_program_runs_without_blocking_or_transport);
  RUN_TEST(test_abort_during_delay_stops_and_allows_no_more_reports);
  RUN_TEST(test_mouse_click_instruction_is_validated_and_emitted);
  RUN_TEST(test_mouse_click_rejects_unknown_button);
  return UNITY_END();
}

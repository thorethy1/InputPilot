#include <unity.h>
#include <cstdio>
#include "FirmwareLogBuffer.h"

void setUp() {}
void tearDown() {}

void test_format_line_is_preserved() {
  FirmwareLogBuffer buffer;
  buffer.append("[1234][INFO][BLE] advertising started");
  FirmwareLogEntry entries[1];
  TEST_ASSERT_EQUAL(1, buffer.copySince(0, entries, 1));
  TEST_ASSERT_EQUAL_STRING("[1234][INFO][BLE] advertising started", entries[0].line);
}

void test_capacity_is_fixed_and_oldest_is_overwritten() {
  FirmwareLogBuffer buffer;
  char line[32];
  for (size_t i = 0; i < FirmwareLogBuffer::Capacity + 3; ++i) {
    snprintf(line, sizeof(line), "line-%u", static_cast<unsigned>(i));
    buffer.append(line);
  }
  FirmwareLogEntry entries[FirmwareLogBuffer::Capacity];
  TEST_ASSERT_EQUAL(FirmwareLogBuffer::Capacity, buffer.size());
  TEST_ASSERT_EQUAL(FirmwareLogBuffer::Capacity,
                    buffer.copySince(0, entries, FirmwareLogBuffer::Capacity));
  TEST_ASSERT_EQUAL_STRING("line-3", entries[0].line);
  TEST_ASSERT_EQUAL(FirmwareLogBuffer::Capacity * FirmwareLogBuffer::LineBytes,
                    FirmwareLogBuffer::StorageBytes);
  TEST_ASSERT_EQUAL(FirmwareLogBuffer::Capacity * sizeof(FirmwareLogEntry),
                    FirmwareLogBuffer::TotalEntryBytes);
}

void test_cursor_and_clear() {
  FirmwareLogBuffer buffer;
  const uint32_t first = buffer.append("one");
  buffer.append("two");
  FirmwareLogEntry entries[2];
  TEST_ASSERT_EQUAL(1, buffer.copySince(first, entries, 2));
  TEST_ASSERT_EQUAL_STRING("two", entries[0].line);
  buffer.clear();
  TEST_ASSERT_EQUAL(0, buffer.size());
  TEST_ASSERT_EQUAL(0, buffer.copySince(0, entries, 2));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_format_line_is_preserved);
  RUN_TEST(test_capacity_is_fixed_and_oldest_is_overwritten);
  RUN_TEST(test_cursor_and_clear);
  return UNITY_END();
}

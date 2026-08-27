#include <unity.h>
#include "HIDEventQueue.h"

void setUp() {} void tearDown() {}

void test_mouse_moves_coalesce_and_preserve_order() {
  HIDEventQueue q;
  TEST_ASSERT_TRUE(q.push(HIDEvent::move(2, 1)));
  TEST_ASSERT_TRUE(q.push(HIDEvent::move(3, 2)));
  TEST_ASSERT_TRUE(q.push(HIDEvent::move(1, 0)));
  TEST_ASSERT_EQUAL(1, q.size());
  HIDEvent e; TEST_ASSERT_TRUE(q.pop(e));
  TEST_ASSERT_EQUAL(6, e.dx); TEST_ASSERT_EQUAL(3, e.dy);
}

void test_capacity_is_bounded_and_reserved_for_critical_events() {
  HIDEventQueue q;
  for (size_t i = 0; i < HIDEventQueue::Capacity - HIDEventQueue::CriticalReserve; ++i) {
    HIDEvent e; e.type = HIDEventType::Click; TEST_ASSERT_TRUE(q.push(e));
  }
  HIDEvent normal; normal.type = HIDEventType::Click;
  TEST_ASSERT_FALSE(q.push(normal));
  HIDEvent up; up.type = HIDEventType::ButtonUp;
  for (size_t i = 0; i < HIDEventQueue::CriticalReserve; ++i) TEST_ASSERT_TRUE(q.push(up));
  TEST_ASSERT_EQUAL(HIDEventQueue::Capacity, q.size());
}

void test_release_all_is_never_lost_and_supersedes_pending_input() {
  HIDEventQueue q;
  for (size_t i = 0; i < HIDEventQueue::Capacity; ++i) {
    HIDEvent e; e.type = HIDEventType::ButtonDown; TEST_ASSERT_TRUE(q.push(e));
  }
  TEST_ASSERT_TRUE(q.push(HIDEvent::releaseAll()));
  TEST_ASSERT_EQUAL(1, q.size());
  HIDEvent event; TEST_ASSERT_TRUE(q.pop(event));
  TEST_ASSERT_EQUAL(HIDEventType::ReleaseAll, event.type);
}

void test_button_up_replaces_mouse_move_when_completely_full() {
  HIDEventQueue q;
  HIDEvent down; down.type = HIDEventType::ButtonDown;
  TEST_ASSERT_TRUE(q.push(HIDEvent::move(1, 1)));
  for (size_t i = 0; i < HIDEventQueue::Capacity - 1; ++i) TEST_ASSERT_TRUE(q.push(down));
  HIDEvent up; up.type = HIDEventType::ButtonUp;
  TEST_ASSERT_TRUE(q.push(up));
  TEST_ASSERT_EQUAL(HIDEventQueue::Capacity, q.size());
  HIDEvent event; bool foundUp = false;
  while (q.pop(event)) if (event.type == HIDEventType::ButtonUp) foundUp = true;
  TEST_ASSERT_TRUE(foundUp);
}

void test_pause_keeps_serial_hidtest_moves_separate() {
  HIDEventQueue q;
  TEST_ASSERT_TRUE(q.push(HIDEvent::move(20, 0)));
  TEST_ASSERT_TRUE(q.push(HIDEvent::pause(150)));
  TEST_ASSERT_TRUE(q.push(HIDEvent::move(-20, 0)));
  TEST_ASSERT_EQUAL_UINT32(3, q.size());
  HIDEvent event;
  TEST_ASSERT_TRUE(q.pop(event)); TEST_ASSERT_EQUAL_INT(20, event.dx);
  TEST_ASSERT_TRUE(q.pop(event)); TEST_ASSERT_EQUAL_UINT8(static_cast<uint8_t>(HIDEventType::Pause), static_cast<uint8_t>(event.type));
  TEST_ASSERT_TRUE(q.pop(event)); TEST_ASSERT_EQUAL_INT(-20, event.dx);
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_mouse_moves_coalesce_and_preserve_order);
  RUN_TEST(test_capacity_is_bounded_and_reserved_for_critical_events);
  RUN_TEST(test_release_all_is_never_lost_and_supersedes_pending_input);
  RUN_TEST(test_button_up_replaces_mouse_move_when_completely_full);
  RUN_TEST(test_pause_keeps_serial_hidtest_moves_separate);
  return UNITY_END();
}

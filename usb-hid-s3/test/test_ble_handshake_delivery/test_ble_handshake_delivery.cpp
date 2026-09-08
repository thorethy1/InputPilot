#include <unity.h>
#include "BLEHandshakeDelivery.h"

void test_default_mtu_and_backpressure_preserve_handshake() {
  BLEHandshakeDelivery delivery;
  const std::string reply = "secure ready " + std::string(64, 'A');
  delivery.queue(reply, 1, 0);
  std::string received;
  delivery.flush(1, true, 23, 0, [](const uint8_t *, size_t) { return false; });
  for (uint32_t now = 20; now <= 120; now += 20) {
    delivery.flush(1, true, 23, now, [&](const uint8_t *data, size_t size) {
      TEST_ASSERT_LESS_OR_EQUAL(20, size);
      received.append(reinterpret_cast<const char *>(data), size);
      return true;
    });
  }
  TEST_ASSERT_EQUAL_STRING(reply.c_str(), received.c_str());
}

void test_large_mtu_keeps_legacy_whole_reply() {
  BLEHandshakeDelivery delivery;
  const std::string reply = "secure challenge 1 aabbccddeeff " + std::string(32, 'A');
  delivery.queue(reply, 1, 0);
  int count = 0;
  delivery.flush(1, true, 185, 0, [&](const uint8_t *data, size_t size) {
    ++count;
    TEST_ASSERT_EQUAL_STRING(reply.c_str(), std::string(reinterpret_cast<const char *>(data), size).c_str());
    return true;
  });
  TEST_ASSERT_EQUAL_INT(1, count);
}

void test_stale_disconnected_and_expired_replies_are_discarded() {
  BLEHandshakeDelivery delivery;
  int sent = 0;
  auto sender = [&](const uint8_t *, size_t) { ++sent; return true; };
  delivery.queue("secure failed", 1, 0);
  delivery.flush(2, true, 185, 0, sender);
  delivery.queue("secure failed", 2, 0);
  delivery.flush(2, false, 185, 0, sender);
  delivery.queue("secure failed", 2, UINT32_MAX - 99);
  delivery.flush(2, true, 185, 14900, sender);
  TEST_ASSERT_EQUAL_INT(0, sent);
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_default_mtu_and_backpressure_preserve_handshake);
  RUN_TEST(test_large_mtu_keeps_legacy_whole_reply);
  RUN_TEST(test_stale_disconnected_and_expired_replies_are_discarded);
  return UNITY_END();
}

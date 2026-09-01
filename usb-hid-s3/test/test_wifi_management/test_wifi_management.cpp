#include <unity.h>

#include <string>

#include "WifiManagement.h"

namespace {

class FakeBackend final : public WifiManagement::Backend {
 public:
  bool saveResult = true;
  bool removeResult = true;
  bool clearResult = true;
  unsigned saveCalls = 0;
  unsigned removeCalls = 0;
  unsigned clearCalls = 0;
  unsigned applyCalls = 0;
  std::string savedSsid;
  std::string savedPassword;
  std::string removedSsid;
  std::string appliedSsid;

  bool save(const std::string &ssid, const std::string &password) override {
    ++saveCalls;
    savedSsid = ssid;
    savedPassword = password;
    return saveResult;
  }

  bool remove(const std::string &ssid) override {
    ++removeCalls;
    removedSsid = ssid;
    return removeResult;
  }

  bool clear() override {
    ++clearCalls;
    return clearResult;
  }

  void apply(const std::string &provisionedSsid) override {
    ++applyCalls;
    appliedSsid = provisionedSsid;
  }
};

}  // namespace

void test_set_persists_then_defers_radio_transition() {
  FakeBackend backend;
  const WifiManagement::Result result =
      WifiManagement::set(backend, "Office", "secret");

  TEST_ASSERT_TRUE(result.accepted());
  TEST_ASSERT_EQUAL_UINT(1, backend.saveCalls);
  TEST_ASSERT_EQUAL_STRING("Office", backend.savedSsid.c_str());
  TEST_ASSERT_EQUAL_UINT(0, backend.applyCalls);
  TEST_ASSERT_EQUAL_STRING(
      "{\"operation\":\"wifi_set\",\"status\":\"accepted\"}",
      WifiManagement::acceptedReply(result.operation));

  WifiManagement::apply(backend, result);
  TEST_ASSERT_EQUAL_UINT(1, backend.applyCalls);
  TEST_ASSERT_EQUAL_STRING("Office", backend.appliedSsid.c_str());
}

void test_set_rejects_invalid_credentials_before_storage() {
  FakeBackend backend;
  const WifiManagement::Result empty = WifiManagement::set(backend, "", "pw");
  const WifiManagement::Result longPassword =
      WifiManagement::set(backend, "Office", std::string(64, 'x'));
  const WifiManagement::Result embeddedNull =
      WifiManagement::set(backend, std::string("bad\0ssid", 8), "pw");

  TEST_ASSERT_EQUAL_INT(static_cast<int>(WifiManagement::Error::InvalidCredentials),
                        static_cast<int>(empty.error));
  TEST_ASSERT_EQUAL_INT(static_cast<int>(WifiManagement::Error::InvalidCredentials),
                        static_cast<int>(longPassword.error));
  TEST_ASSERT_EQUAL_INT(static_cast<int>(WifiManagement::Error::InvalidCredentials),
                        static_cast<int>(embeddedNull.error));
  TEST_ASSERT_EQUAL_UINT(0, backend.saveCalls);
  WifiManagement::apply(backend, empty);
  TEST_ASSERT_EQUAL_UINT(0, backend.applyCalls);
}

void test_set_reports_storage_failure_without_transition() {
  FakeBackend backend;
  backend.saveResult = false;
  const WifiManagement::Result result =
      WifiManagement::set(backend, "Office", "secret");

  TEST_ASSERT_EQUAL_INT(static_cast<int>(WifiManagement::Error::StorageFailed),
                        static_cast<int>(result.error));
  TEST_ASSERT_EQUAL_STRING("error wifi_storage_failed",
                           WifiManagement::errorReply(result.error));
  WifiManagement::apply(backend, result);
  TEST_ASSERT_EQUAL_UINT(0, backend.applyCalls);
}

void test_remove_uses_shared_validation_and_result_mapping() {
  FakeBackend backend;
  WifiManagement::Result result = WifiManagement::remove(backend, "Office");
  TEST_ASSERT_TRUE(result.accepted());
  TEST_ASSERT_EQUAL_STRING("Office", backend.removedSsid.c_str());
  TEST_ASSERT_EQUAL_UINT(0, backend.applyCalls);
  WifiManagement::apply(backend, result);
  TEST_ASSERT_EQUAL_UINT(1, backend.applyCalls);
  TEST_ASSERT_TRUE(backend.appliedSsid.empty());

  backend.removeResult = false;
  result = WifiManagement::remove(backend, "Missing");
  TEST_ASSERT_EQUAL_INT(static_cast<int>(WifiManagement::Error::NetworkNotFound),
                        static_cast<int>(result.error));
  TEST_ASSERT_EQUAL_STRING("error wifi_network_not_found",
                           WifiManagement::errorReply(result.error));
}

void test_clear_reports_storage_failure_and_applies_only_on_success() {
  FakeBackend backend;
  backend.clearResult = false;
  WifiManagement::Result result = WifiManagement::clear(backend);
  TEST_ASSERT_EQUAL_INT(static_cast<int>(WifiManagement::Error::StorageFailed),
                        static_cast<int>(result.error));
  WifiManagement::apply(backend, result);
  TEST_ASSERT_EQUAL_UINT(0, backend.applyCalls);

  backend.clearResult = true;
  result = WifiManagement::clear(backend);
  TEST_ASSERT_TRUE(result.accepted());
  WifiManagement::apply(backend, result);
  TEST_ASSERT_EQUAL_UINT(1, backend.applyCalls);
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_set_persists_then_defers_radio_transition);
  RUN_TEST(test_set_rejects_invalid_credentials_before_storage);
  RUN_TEST(test_set_reports_storage_failure_without_transition);
  RUN_TEST(test_remove_uses_shared_validation_and_result_mapping);
  RUN_TEST(test_clear_reports_storage_failure_and_applies_only_on_success);
  return UNITY_END();
}

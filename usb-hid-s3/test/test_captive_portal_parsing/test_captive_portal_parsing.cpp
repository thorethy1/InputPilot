#include <unity.h>

#include <map>
#include <string>
#include <vector>

#include "CaptivePortalParsing.h"

using CaptivePortalParsing::CaptureResult;
using CaptivePortalParsing::VariableComparison;

namespace {

void assertObjectCapture(const std::string &body, const char *expected) {
  std::string value;
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Found),
      static_cast<int>(CaptivePortalParsing::captureObjectString(
          body.data(), body.size(), "token", 1024, value)));
  TEST_ASSERT_EQUAL_STRING(expected, value.c_str());
}

void test_object_string_accepts_supported_whitespace() {
  assertObjectCapture(R"({"token":"abc"})", "abc");
  assertObjectCapture(R"({"token": "abc"})", "abc");
  assertObjectCapture(R"({"token" : "abc"})", "abc");
  assertObjectCapture(R"(<script>foo = {"token"   :   "abc"};</script>)", "abc");
}

void test_object_string_reports_missing_key() {
  const std::string body = R"({"other":"abc"})";
  std::string value;
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Missing),
      static_cast<int>(CaptivePortalParsing::captureObjectString(
          body.data(), body.size(), "token", 1024, value)));
}

void test_object_string_rejects_oversized_value() {
  const std::string body = std::string("{\"token\":\"") +
                           std::string(1025, 'a') + "\"}";
  std::string value;
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::TooLarge),
      static_cast<int>(CaptivePortalParsing::captureObjectString(
          body.data(), body.size(), "token", 1024, value)));
}

void test_object_string_decodes_escaped_string() {
  assertObjectCapture(R"({"token":"a\"b\\c\n\u00e4"})", "a\"b\\c\nä");
}

void test_object_string_rejects_malformed_input_and_key() {
  const std::string body = R"({"token":"unterminated})";
  std::string value;
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Malformed),
      static_cast<int>(CaptivePortalParsing::captureObjectString(
          body.data(), body.size(), "token", 1024, value)));
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Malformed),
      static_cast<int>(CaptivePortalParsing::captureObjectString(
          body.data(), body.size(), "bad.key", 1024, value)));
}

void test_json_first_uses_first_available_scalar() {
  std::string value;
  const std::vector<std::string> paths = {"session", "payload.session"};
  const std::string direct = R"({"session":"one"})";
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Found),
      static_cast<int>(CaptivePortalParsing::captureFirstJsonScalar(
          direct.data(), direct.size(), paths, 1024, value)));
  TEST_ASSERT_EQUAL_STRING("one", value.c_str());

  const std::string nested = R"({"payload":{"session":"two"}})";
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Found),
      static_cast<int>(CaptivePortalParsing::captureFirstJsonScalar(
          nested.data(), nested.size(), paths, 1024, value)));
  TEST_ASSERT_EQUAL_STRING("two", value.c_str());
}

void test_json_first_skips_empty_string() {
  std::string value;
  const std::string body = R"({"session":"","payload":{"session":"two"}})";
  const std::vector<std::string> paths = {"session", "payload.session"};
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Found),
      static_cast<int>(CaptivePortalParsing::captureFirstJsonScalar(
          body.data(), body.size(), paths, 1024, value)));
  TEST_ASSERT_EQUAL_STRING("two", value.c_str());
}

void test_json_first_supports_boolean_and_number_scalars() {
  std::string value;
  const std::string body = R"({"ok":true,"attempt":3})";
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Found),
      static_cast<int>(CaptivePortalParsing::captureFirstJsonScalar(
          body.data(), body.size(), {"ok"}, 1024, value)));
  TEST_ASSERT_EQUAL_STRING("true", value.c_str());
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Found),
      static_cast<int>(CaptivePortalParsing::captureFirstJsonScalar(
          body.data(), body.size(), {"attempt"}, 1024, value)));
  TEST_ASSERT_EQUAL_STRING("3", value.c_str());
}

void test_json_first_reports_missing_malformed_and_oversized() {
  std::string value;
  const std::vector<std::string> paths = {"session", "payload.session"};
  const std::string missing = R"({"other":true})";
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Missing),
      static_cast<int>(CaptivePortalParsing::captureFirstJsonScalar(
          missing.data(), missing.size(), paths, 1024, value)));
  const std::string malformed = R"({"session":)";
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::Malformed),
      static_cast<int>(CaptivePortalParsing::captureFirstJsonScalar(
          malformed.data(), malformed.size(), paths, 1024, value)));
  const std::string oversized = std::string("{\"session\":\"") +
                                std::string(1025, 'a') + "\"}";
  TEST_ASSERT_EQUAL(
      static_cast<int>(CaptureResult::TooLarge),
      static_cast<int>(CaptivePortalParsing::captureFirstJsonScalar(
          oversized.data(), oversized.size(), paths, 1024, value)));
}

void test_variable_comparison_covers_true_false_and_missing() {
  TEST_ASSERT_EQUAL(
      static_cast<int>(VariableComparison::Equal),
      static_cast<int>(CaptivePortalParsing::compareVariable("true", "true")));
  TEST_ASSERT_EQUAL(
      static_cast<int>(VariableComparison::NotEqual),
      static_cast<int>(CaptivePortalParsing::compareVariable("false", "true")));
  TEST_ASSERT_EQUAL(
      static_cast<int>(VariableComparison::Missing),
      static_cast<int>(CaptivePortalParsing::compareVariable(nullptr, "true")));
}

void test_body_equals_trims_only_body_edges() {
  const char *expected = "success";
  for (const std::string &body : {std::string("success"), std::string("success\n"),
                                  std::string(" success \r\n")}) {
    TEST_ASSERT_TRUE(CaptivePortalParsing::bodyEqualsTrimmed(
        body.data(), body.size(), expected, 7));
  }
  const std::string html = "<html>success</html>";
  TEST_ASSERT_FALSE(CaptivePortalParsing::bodyEqualsTrimmed(
      html.data(), html.size(), expected, 7));
}

}  // namespace

void setUp() {}
void tearDown() {}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_object_string_accepts_supported_whitespace);
  RUN_TEST(test_object_string_reports_missing_key);
  RUN_TEST(test_object_string_rejects_oversized_value);
  RUN_TEST(test_object_string_decodes_escaped_string);
  RUN_TEST(test_object_string_rejects_malformed_input_and_key);
  RUN_TEST(test_json_first_uses_first_available_scalar);
  RUN_TEST(test_json_first_skips_empty_string);
  RUN_TEST(test_json_first_supports_boolean_and_number_scalars);
  RUN_TEST(test_json_first_reports_missing_malformed_and_oversized);
  RUN_TEST(test_variable_comparison_covers_true_false_and_missing);
  RUN_TEST(test_body_equals_trims_only_body_edges);
  return UNITY_END();
}

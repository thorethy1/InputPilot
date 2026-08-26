#include <unity.h>

#include <string>

#include "Config.h"
#include "FirmwareMetadata.h"

void setUp() {}
void tearDown() {}

static FirmwareMetadataValue parse(const std::string &value) {
  FirmwareMetadataValue metadata;
  TEST_ASSERT_TRUE(FirmwareMetadata::parse(
      reinterpret_cast<const uint8_t *>(value.data()), value.size() + 1, metadata));
  return metadata;
}

void test_parses_inputpilot_metadata_inside_image() {
  std::string image = FW_METADATA_PREFIX;
  image.push_back('\0');
  image += "noise" FW_METADATA_PREFIX "product=InputPilot;board=esp32-s3-zero-4mb;version=0.8.0;protocol=1;otaSchema=1;";
  auto value = parse(image);
  TEST_ASSERT_EQUAL_STRING("InputPilot", value.product.c_str());
  TEST_ASSERT_EQUAL_STRING("0.8.0", value.version.c_str());
}

void test_rejects_foreign_product() {
  auto value = parse(FW_METADATA_PREFIX "product=Other;board=esp32-s3-zero-4mb;version=1.0.0;protocol=1;otaSchema=1;");
  std::string error;
  TEST_ASSERT_FALSE(FirmwareMetadata::compatible(value, error));
  TEST_ASSERT_EQUAL_STRING("incompatible_product", error.c_str());
}

void test_rejects_wrong_board_and_protocol() {
  auto board = parse(FW_METADATA_PREFIX "product=InputPilot;board=other;version=0.8.0;protocol=1;otaSchema=1;");
  std::string error;
  TEST_ASSERT_FALSE(FirmwareMetadata::compatible(board, error));
  TEST_ASSERT_EQUAL_STRING("incompatible_board", error.c_str());
  auto protocol = parse(FW_METADATA_PREFIX "product=InputPilot;board=esp32-s3-zero-4mb;version=0.8.0;protocol=2;otaSchema=1;");
  TEST_ASSERT_FALSE(FirmwareMetadata::compatible(protocol, error));
  TEST_ASSERT_EQUAL_STRING("unsupported_protocol", error.c_str());
}

void test_rejects_invalid_metadata() {
  FirmwareMetadataValue value;
  const std::string invalid = FW_METADATA_PREFIX "product=InputPilot;board=esp32-s3-zero-4mb;";
  TEST_ASSERT_FALSE(FirmwareMetadata::parse(
      reinterpret_cast<const uint8_t *>(invalid.data()), invalid.size() + 1, value));
}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_parses_inputpilot_metadata_inside_image);
  RUN_TEST(test_rejects_foreign_product);
  RUN_TEST(test_rejects_wrong_board_and_protocol);
  RUN_TEST(test_rejects_invalid_metadata);
  return UNITY_END();
}

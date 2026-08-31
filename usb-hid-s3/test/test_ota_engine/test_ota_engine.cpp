#include <unity.h>
#include "OTAEngineValidation.h"

void setUp() {} void tearDown() {}
static OTAStartRequest request() { return {2, 100, "0.8.12", std::string(64, 'a')}; }
static FirmwareMetadataValue metadata(const char *product="InputPilot", const char *board="esp32-s3-zero-4mb") { return {product, board, "0.8.12", 2, 1}; }

void test_start_and_concurrent_rejection() { std::string e; TEST_ASSERT_TRUE(OTAEngineValidation::start(false, request(), 200, e)); TEST_ASSERT_FALSE(OTAEngineValidation::start(true, request(), 200, e)); TEST_ASSERT_EQUAL_STRING("update_in_progress", e.c_str()); }
void test_sequential_write_and_invalid_offset() { std::string e; TEST_ASSERT_TRUE(OTAEngineValidation::write(0,0,50,100,e)); TEST_ASSERT_TRUE(OTAEngineValidation::write(50,50,50,100,e)); TEST_ASSERT_FALSE(OTAEngineValidation::write(50,49,10,100,e)); TEST_ASSERT_EQUAL_STRING("invalid_offset",e.c_str()); }
void test_size_and_hash_failures() { std::string e; auto r=request(); TEST_ASSERT_FALSE(OTAEngineValidation::start(false,r,50,e)); TEST_ASSERT_EQUAL_STRING("firmware_too_large",e.c_str()); auto m=metadata(); TEST_ASSERT_FALSE(OTAEngineValidation::completion(100,r,std::string(64,'b'),m,e)); TEST_ASSERT_EQUAL_STRING("checksum_mismatch",e.c_str()); }
void test_metadata_product_board_and_completion() { std::string e; auto r=request(); auto good=metadata(); TEST_ASSERT_TRUE(OTAEngineValidation::completion(100,r,r.sha256,good,e)); auto product=metadata("Other"); TEST_ASSERT_FALSE(OTAEngineValidation::completion(100,r,r.sha256,product,e)); TEST_ASSERT_EQUAL_STRING("incompatible_product",e.c_str()); auto board=metadata("InputPilot","other"); TEST_ASSERT_FALSE(OTAEngineValidation::completion(100,r,r.sha256,board,e)); TEST_ASSERT_EQUAL_STRING("incompatible_board",e.c_str()); }
void test_wrong_size_version_and_protocol() { std::string e; auto r=request(); auto m=metadata(); TEST_ASSERT_FALSE(OTAEngineValidation::completion(99,r,r.sha256,m,e)); TEST_ASSERT_EQUAL_STRING("incomplete_firmware",e.c_str()); m.version="0.8.13"; TEST_ASSERT_FALSE(OTAEngineValidation::completion(100,r,r.sha256,m,e)); TEST_ASSERT_EQUAL_STRING("version_mismatch",e.c_str()); r.protocol=3; TEST_ASSERT_FALSE(OTAEngineValidation::start(false,r,200,e)); TEST_ASSERT_EQUAL_STRING("unsupported_protocol",e.c_str()); }
int main(int,char**){UNITY_BEGIN();RUN_TEST(test_start_and_concurrent_rejection);RUN_TEST(test_sequential_write_and_invalid_offset);RUN_TEST(test_size_and_hash_failures);RUN_TEST(test_metadata_product_board_and_completion);RUN_TEST(test_wrong_size_version_and_protocol);return UNITY_END();}

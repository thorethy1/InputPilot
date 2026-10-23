#include <unity.h>

#include "WireGuardConfigParser.h"

namespace {

const char *validConfig =
    "[Interface]\n"
    "PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n"
    "Address = 10.7.0.23/32\n"
    "MTU = 1280\n"
    "DNS = 10.7.0.1\n"
    "\n"
    "[Peer]\n"
    "PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n"
    "PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=\n"
    "AllowedIPs = 10.7.0.0/24\n"
    "Endpoint = vpn.example.test:51820\n"
    "PersistentKeepalive = 25\n";

void test_parses_supported_single_peer_config() {
  WireGuardConfig config;
  WireGuardConfigError error;
  TEST_ASSERT_TRUE(WireGuardConfigParser::parse(validConfig, config, error));
  TEST_ASSERT_EQUAL(WireGuardConfigError::None, error);
  TEST_ASSERT_EQUAL_STRING("10.7.0.23", config.address.c_str());
  TEST_ASSERT_EQUAL_UINT8(32, config.addressPrefix);
  TEST_ASSERT_EQUAL_UINT16(1280, config.mtu);
  TEST_ASSERT_EQUAL_STRING("vpn.example.test", config.endpointHost.c_str());
  TEST_ASSERT_EQUAL_UINT16(51820, config.endpointPort);
  TEST_ASSERT_EQUAL_STRING("10.7.0.0", config.allowedIP.c_str());
  TEST_ASSERT_EQUAL_UINT8(24, config.allowedPrefix);
  TEST_ASSERT_EQUAL_UINT16(25, config.persistentKeepalive);
  TEST_ASSERT_FALSE(config.presharedKey.empty());
}

void test_accepts_comments_crlf_and_full_tunnel() {
  std::string text =
      "# exported profile\r\n[Interface]\r\n"
      "PrivateKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= # secret\r\n"
      "Address=10.0.0.2/24\r\n[Peer]\r\n"
      "PublicKey=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\r\n"
      "AllowedIPs=0.0.0.0/0\r\nEndpoint=198.51.100.5:42\r\n";
  WireGuardConfig config;
  WireGuardConfigError error;
  TEST_ASSERT_TRUE(WireGuardConfigParser::parse(text, config, error));
  TEST_ASSERT_EQUAL_UINT8(0, config.allowedPrefix);
}

void test_accepts_repeated_dns_and_reported_lan_range() {
  std::string text(validConfig);
  text.insert(text.find("[Peer]"), "DNS = 1.1.1.1\n");
  const std::string address = "Address = 10.7.0.23/32";
  text.replace(text.find(address), address.size(), "Address = 192.168.178.209/24");
  const std::string allowed = "AllowedIPs = 10.7.0.0/24";
  text.replace(text.find(allowed), allowed.size(), "AllowedIPs = 192.168.178.0/24");
  WireGuardConfig config;
  WireGuardConfigError error;
  TEST_ASSERT_TRUE(WireGuardConfigParser::parse(text, config, error));
  TEST_ASSERT_EQUAL_STRING("192.168.178.209", config.address.c_str());
  TEST_ASSERT_EQUAL_STRING("192.168.178.0", config.allowedIP.c_str());
  TEST_ASSERT_EQUAL_UINT16(25, config.persistentKeepalive);
}

void test_rejects_multiple_peers() {
  std::string text(validConfig);
  text += "\n[Peer]\nPublicKey = DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=\n";
  WireGuardConfig config;
  WireGuardConfigError error;
  TEST_ASSERT_FALSE(WireGuardConfigParser::parse(text, config, error));
  TEST_ASSERT_EQUAL(WireGuardConfigError::MultiplePeers, error);
}

void test_rejects_multiple_allowed_ranges() {
  std::string text(validConfig);
  const std::string original = "AllowedIPs = 10.7.0.0/24";
  text.replace(text.find(original), original.size(),
               "AllowedIPs = 10.7.0.0/24, 192.168.1.0/24");
  WireGuardConfig config;
  WireGuardConfigError error;
  TEST_ASSERT_FALSE(WireGuardConfigParser::parse(text, config, error));
  TEST_ASSERT_EQUAL(WireGuardConfigError::MultipleAllowedIPs, error);
}

void test_rejects_ipv6_and_script_hooks() {
  std::string ipv6(validConfig);
  const std::string address = "Address = 10.7.0.23/32";
  ipv6.replace(ipv6.find(address), address.size(), "Address = fd00::23/128");
  WireGuardConfig config;
  WireGuardConfigError error;
  TEST_ASSERT_FALSE(WireGuardConfigParser::parse(ipv6, config, error));
  TEST_ASSERT_EQUAL(WireGuardConfigError::UnsupportedIPv6, error);

  std::string hook(validConfig);
  hook.insert(hook.find("Address"), "PostUp = reboot\n");
  TEST_ASSERT_FALSE(WireGuardConfigParser::parse(hook, config, error));
  TEST_ASSERT_EQUAL(WireGuardConfigError::UnsupportedKey, error);
}

void test_rejects_unroutable_allowed_range_and_long_endpoint() {
  std::string route(validConfig);
  const std::string allowed = "AllowedIPs = 10.7.0.0/24";
  route.replace(route.find(allowed), allowed.size(), "AllowedIPs = 192.168.50.0/24");
  WireGuardConfig config;
  WireGuardConfigError error;
  TEST_ASSERT_FALSE(WireGuardConfigParser::parse(route, config, error));
  TEST_ASSERT_EQUAL(WireGuardConfigError::AllowedIPsRouteMismatch, error);

  std::string endpoint(validConfig);
  const std::string original = "vpn.example.test:51820";
  endpoint.replace(endpoint.find(original), original.size(), std::string(97, 'a') + ":51820");
  TEST_ASSERT_FALSE(WireGuardConfigParser::parse(endpoint, config, error));
  TEST_ASSERT_EQUAL(WireGuardConfigError::InvalidEndpoint, error);
}

}  // namespace

void setUp() {}
void tearDown() {}

int main(int, char **) {
  UNITY_BEGIN();
  RUN_TEST(test_parses_supported_single_peer_config);
  RUN_TEST(test_accepts_comments_crlf_and_full_tunnel);
  RUN_TEST(test_accepts_repeated_dns_and_reported_lan_range);
  RUN_TEST(test_rejects_multiple_peers);
  RUN_TEST(test_rejects_multiple_allowed_ranges);
  RUN_TEST(test_rejects_ipv6_and_script_hooks);
  RUN_TEST(test_rejects_unroutable_allowed_range_and_long_endpoint);
  return UNITY_END();
}

#ifndef INPUTPILOT_WIREGUARD_CONFIG_PARSER_H
#define INPUTPILOT_WIREGUARD_CONFIG_PARSER_H

#include <cstdint>
#include <string>

struct WireGuardConfig {
  std::string privateKey;
  std::string address;
  uint8_t addressPrefix = 32;
  uint16_t mtu = 1420;
  uint16_t listenPort = 0;
  std::string publicKey;
  std::string presharedKey;
  std::string endpointHost;
  uint16_t endpointPort = 0;
  std::string allowedIP;
  uint8_t allowedPrefix = 0;
  uint16_t persistentKeepalive = 0;
};

enum class WireGuardConfigError {
  None,
  Empty,
  TooLarge,
  InvalidLine,
  InvalidSection,
  UnsupportedKey,
  DuplicateKey,
  MultipleInterfaces,
  MultiplePeers,
  MissingInterface,
  MissingPeer,
  MissingPrivateKey,
  MissingAddress,
  MissingPublicKey,
  MissingEndpoint,
  MissingAllowedIPs,
  InvalidKey,
  InvalidAddress,
  InvalidPort,
  InvalidEndpoint,
  InvalidKeepalive,
  UnsupportedMTU,
  UnsupportedIPv6,
  MultipleAddresses,
  MultipleAllowedIPs,
  AllowedIPsRouteMismatch,
};

class WireGuardConfigParser {
 public:
  static constexpr size_t MaxConfigBytes = 2048;

  static bool parse(const std::string &text, WireGuardConfig &config,
                    WireGuardConfigError &error);
  static const char *errorCode(WireGuardConfigError error);
};

#endif  // INPUTPILOT_WIREGUARD_CONFIG_PARSER_H

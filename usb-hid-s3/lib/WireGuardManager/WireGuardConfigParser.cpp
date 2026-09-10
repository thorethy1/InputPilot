#include "WireGuardConfigParser.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <map>
#include <sstream>

namespace {

enum class Section { None, Interface, Peer };

std::string trim(const std::string &value) {
  const size_t first = value.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  const size_t last = value.find_last_not_of(" \t\r\n");
  return value.substr(first, last - first + 1);
}

std::string lowercase(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return value;
}

bool validBase64Key(const std::string &value) {
  if (value.size() != 44 || value.back() != '=') return false;
  for (size_t i = 0; i + 1 < value.size(); ++i) {
    const unsigned char c = static_cast<unsigned char>(value[i]);
    if (!std::isalnum(c) && c != '+' && c != '/') return false;
  }
  return true;
}

bool parseUnsigned(const std::string &value, unsigned long maximum,
                   unsigned long &result) {
  if (value.empty()) return false;
  char *end = nullptr;
  const unsigned long parsed = std::strtoul(value.c_str(), &end, 10);
  if (!end || *end || parsed > maximum) return false;
  result = parsed;
  return true;
}

bool parseIPv4(const std::string &value, uint32_t *result = nullptr) {
  size_t start = 0;
  uint32_t parsedAddress = 0;
  for (int octet = 0; octet < 4; ++octet) {
    const size_t end = value.find('.', start);
    if ((octet < 3 && end == std::string::npos) ||
        (octet == 3 && end != std::string::npos)) return false;
    const std::string part = value.substr(
        start, end == std::string::npos ? std::string::npos : end - start);
    unsigned long number = 0;
    if (part.empty() || (part.size() > 1 && part.front() == '0') ||
        !parseUnsigned(part, 255, number)) return false;
    parsedAddress = (parsedAddress << 8) | number;
    start = end == std::string::npos ? value.size() : end + 1;
  }
  if (start != value.size()) return false;
  if (result) *result = parsedAddress;
  return true;
}

bool parseRange(const std::string &value, std::string &address,
                uint8_t &prefix, WireGuardConfigError &error) {
  if (value.find(':') != std::string::npos) {
    error = WireGuardConfigError::UnsupportedIPv6;
    return false;
  }
  const size_t slash = value.find('/');
  if (slash == std::string::npos || value.find('/', slash + 1) != std::string::npos) {
    error = WireGuardConfigError::InvalidAddress;
    return false;
  }
  address = trim(value.substr(0, slash));
  unsigned long parsedPrefix = 0;
  if (!parseIPv4(address) ||
      !parseUnsigned(trim(value.substr(slash + 1)), 32, parsedPrefix)) {
    error = WireGuardConfigError::InvalidAddress;
    return false;
  }
  prefix = static_cast<uint8_t>(parsedPrefix);
  return true;
}

bool allowedKey(Section section, const std::string &key) {
  if (section == Section::Interface) {
    return key == "privatekey" || key == "address" || key == "listenport" ||
           key == "dns" || key == "mtu";
  }
  if (section == Section::Peer) {
    return key == "publickey" || key == "presharedkey" ||
           key == "endpoint" || key == "allowedips" ||
           key == "persistentkeepalive";
  }
  return false;
}

bool validEndpointHost(const std::string &host) {
  if (host.empty() || host.size() > 96) return false;
  return std::all_of(host.begin(), host.end(), [](unsigned char c) {
    return std::isalnum(c) || c == '.' || c == '-' || c == '_';
  });
}

}  // namespace

bool WireGuardConfigParser::parse(const std::string &text,
                                  WireGuardConfig &config,
                                  WireGuardConfigError &error) {
  config = {};
  error = WireGuardConfigError::None;
  if (text.empty()) { error = WireGuardConfigError::Empty; return false; }
  if (text.size() > MaxConfigBytes) { error = WireGuardConfigError::TooLarge; return false; }

  Section section = Section::None;
  size_t interfaceCount = 0;
  size_t peerCount = 0;
  std::map<std::string, std::string> interfaceValues;
  std::map<std::string, std::string> peerValues;
  std::istringstream stream(text);
  std::string rawLine;
  while (std::getline(stream, rawLine)) {
    const size_t comment = rawLine.find('#');
    const std::string line = trim(rawLine.substr(0, comment));
    if (line.empty()) continue;
    const std::string lower = lowercase(line);
    if (lower == "[interface]") {
      if (++interfaceCount > 1) { error = WireGuardConfigError::MultipleInterfaces; return false; }
      section = Section::Interface;
      continue;
    }
    if (lower == "[peer]") {
      if (++peerCount > 1) { error = WireGuardConfigError::MultiplePeers; return false; }
      section = Section::Peer;
      continue;
    }
    if (!line.empty() && line.front() == '[') {
      error = WireGuardConfigError::InvalidSection;
      return false;
    }
    const size_t equals = line.find('=');
    if (section == Section::None || equals == std::string::npos) {
      error = WireGuardConfigError::InvalidLine;
      return false;
    }
    const std::string key = lowercase(trim(line.substr(0, equals)));
    const std::string value = trim(line.substr(equals + 1));
    if (key.empty() || value.empty()) { error = WireGuardConfigError::InvalidLine; return false; }
    if (!allowedKey(section, key)) { error = WireGuardConfigError::UnsupportedKey; return false; }
    auto &values = section == Section::Interface ? interfaceValues : peerValues;
    // wg-quick permits more than one DNS entry. DNS is intentionally ignored
    // at runtime because endpoint lookup must continue using the Wi-Fi DNS.
    if (values.count(key) && key != "dns") {
      error = WireGuardConfigError::DuplicateKey;
      return false;
    }
    values[key] = value;
  }

  if (interfaceCount == 0) { error = WireGuardConfigError::MissingInterface; return false; }
  if (peerCount == 0) { error = WireGuardConfigError::MissingPeer; return false; }
  const auto privateKey = interfaceValues.find("privatekey");
  if (privateKey == interfaceValues.end()) { error = WireGuardConfigError::MissingPrivateKey; return false; }
  if (!validBase64Key(privateKey->second)) { error = WireGuardConfigError::InvalidKey; return false; }
  config.privateKey = privateKey->second;

  const auto address = interfaceValues.find("address");
  if (address == interfaceValues.end()) { error = WireGuardConfigError::MissingAddress; return false; }
  if (address->second.find(',') != std::string::npos) { error = WireGuardConfigError::MultipleAddresses; return false; }
  if (!parseRange(address->second, config.address, config.addressPrefix, error)) return false;

  if (const auto listen = interfaceValues.find("listenport"); listen != interfaceValues.end()) {
    unsigned long value = 0;
    if (!parseUnsigned(listen->second, 65535, value) || value == 0) {
      error = WireGuardConfigError::InvalidPort; return false;
    }
    config.listenPort = static_cast<uint16_t>(value);
  }
  if (const auto mtu = interfaceValues.find("mtu"); mtu != interfaceValues.end()) {
    unsigned long value = 0;
    if (!parseUnsigned(mtu->second, 1420, value) || value < 576) {
      error = WireGuardConfigError::UnsupportedMTU; return false;
    }
    config.mtu = static_cast<uint16_t>(value);
  }

  const auto publicKey = peerValues.find("publickey");
  if (publicKey == peerValues.end()) { error = WireGuardConfigError::MissingPublicKey; return false; }
  if (!validBase64Key(publicKey->second)) { error = WireGuardConfigError::InvalidKey; return false; }
  config.publicKey = publicKey->second;
  if (const auto psk = peerValues.find("presharedkey"); psk != peerValues.end()) {
    if (!validBase64Key(psk->second)) { error = WireGuardConfigError::InvalidKey; return false; }
    config.presharedKey = psk->second;
  }

  const auto endpoint = peerValues.find("endpoint");
  if (endpoint == peerValues.end()) { error = WireGuardConfigError::MissingEndpoint; return false; }
  if (endpoint->second.empty() || endpoint->second.front() == '[' ||
      endpoint->second.find(':') != endpoint->second.rfind(':')) {
    error = endpoint->second.find(']') != std::string::npos
                ? WireGuardConfigError::UnsupportedIPv6
                : WireGuardConfigError::InvalidPort;
    return false;
  }
  const size_t colon = endpoint->second.rfind(':');
  unsigned long port = 0;
  config.endpointHost = trim(endpoint->second.substr(0, colon));
  if (colon == std::string::npos || !validEndpointHost(config.endpointHost) ||
      !parseUnsigned(trim(endpoint->second.substr(colon + 1)), 65535, port) || port == 0) {
    error = WireGuardConfigError::InvalidEndpoint; return false;
  }
  config.endpointPort = static_cast<uint16_t>(port);

  const auto allowed = peerValues.find("allowedips");
  if (allowed == peerValues.end()) { error = WireGuardConfigError::MissingAllowedIPs; return false; }
  if (allowed->second.find(',') != std::string::npos) { error = WireGuardConfigError::MultipleAllowedIPs; return false; }
  if (!parseRange(allowed->second, config.allowedIP, config.allowedPrefix, error)) return false;
  uint32_t interfaceAddress = 0, allowedAddress = 0;
  parseIPv4(config.address, &interfaceAddress);
  parseIPv4(config.allowedIP, &allowedAddress);
  const uint32_t allowedMask = config.allowedPrefix == 0
      ? 0 : 0xffffffffUL << (32 - config.allowedPrefix);
  if ((interfaceAddress & allowedMask) != (allowedAddress & allowedMask)) {
    // lwIP has no general route table for this custom netif. Requiring the
    // interface address inside AllowedIPs lets its netmask provide the route
    // without hijacking unrelated traffic through the default interface.
    error = WireGuardConfigError::AllowedIPsRouteMismatch;
    return false;
  }

  if (const auto keepalive = peerValues.find("persistentkeepalive"); keepalive != peerValues.end()) {
    unsigned long value = 0;
    if (!parseUnsigned(keepalive->second, 65535, value)) {
      error = WireGuardConfigError::InvalidKeepalive; return false;
    }
    config.persistentKeepalive = static_cast<uint16_t>(value);
  }
  return true;
}

const char *WireGuardConfigParser::errorCode(WireGuardConfigError error) {
  switch (error) {
    case WireGuardConfigError::None: return "none";
    case WireGuardConfigError::Empty: return "empty";
    case WireGuardConfigError::TooLarge: return "too_large";
    case WireGuardConfigError::InvalidLine: return "invalid_line";
    case WireGuardConfigError::InvalidSection: return "invalid_section";
    case WireGuardConfigError::UnsupportedKey: return "unsupported_key";
    case WireGuardConfigError::DuplicateKey: return "duplicate_key";
    case WireGuardConfigError::MultipleInterfaces: return "multiple_interfaces";
    case WireGuardConfigError::MultiplePeers: return "multiple_peers";
    case WireGuardConfigError::MissingInterface: return "missing_interface";
    case WireGuardConfigError::MissingPeer: return "missing_peer";
    case WireGuardConfigError::MissingPrivateKey: return "missing_private_key";
    case WireGuardConfigError::MissingAddress: return "missing_address";
    case WireGuardConfigError::MissingPublicKey: return "missing_public_key";
    case WireGuardConfigError::MissingEndpoint: return "missing_endpoint";
    case WireGuardConfigError::MissingAllowedIPs: return "missing_allowed_ips";
    case WireGuardConfigError::InvalidKey: return "invalid_key";
    case WireGuardConfigError::InvalidAddress: return "invalid_address";
    case WireGuardConfigError::InvalidPort: return "invalid_port";
    case WireGuardConfigError::InvalidEndpoint: return "invalid_endpoint";
    case WireGuardConfigError::InvalidKeepalive: return "invalid_keepalive";
    case WireGuardConfigError::UnsupportedMTU: return "unsupported_mtu";
    case WireGuardConfigError::UnsupportedIPv6: return "ipv6_unsupported";
    case WireGuardConfigError::MultipleAddresses: return "multiple_addresses";
    case WireGuardConfigError::MultipleAllowedIPs: return "multiple_allowed_ips";
    case WireGuardConfigError::AllowedIPsRouteMismatch: return "allowed_ips_route_mismatch";
  }
  return "invalid";
}

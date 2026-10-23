#include "WireGuardManager.h"

#include <Preferences.h>
#include <WiFi.h>
#include <algorithm>
#include <cstring>
#include <ctime>

#include <mbedtls/base64.h>

extern "C" {
#include "lwip/err.h"
#include "lwip/ip.h"
#include "lwip/netdb.h"
#include "lwip/tcpip.h"
#include "wireguard-platform.h"
#include "wireguardif.h"
}

#include "Config.h"
#include "CaptivePortalAutomation.h"
#include "Logging.h"

WireGuardManager g_wireGuardManager;

namespace {

constexpr const char *kNamespace = "wireguard";
constexpr const char *kConfigKey = "config";
constexpr const char *kEnabledKey = "enabled";
constexpr const char *kRestrictedKey = "restricted";
constexpr const char *kSSIDCountKey = "ssid_count";
constexpr time_t kMinimumValidTime = 1704067200;  // 2024-01-01 UTC
constexpr uint32_t kTimeSyncTimeoutMs = 30000;

class LwipCoreLock {
 public:
  LwipCoreLock() { LOCK_TCPIP_CORE(); }
  ~LwipCoreLock() { UNLOCK_TCPIP_CORE(); }
  LwipCoreLock(const LwipCoreLock &) = delete;
  LwipCoreLock &operator=(const LwipCoreLock &) = delete;
};

bool parseUnsigned(const std::string &text, unsigned long maximum,
                   unsigned long &result, int base = 10) {
  if (text.empty()) return false;
  char *end = nullptr;
  const unsigned long parsed = strtoul(text.c_str(), &end, base);
  if (!end || *end || parsed > maximum) return false;
  result = parsed;
  return true;
}

bool parseToken(const std::string &text, uint64_t &value) {
  if (text.empty() || text.size() > 16) return false;
  char *end = nullptr;
  value = strtoull(text.c_str(), &end, 16);
  return end && !*end && value != 0;
}

int nibble(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

bool decodeHex(const std::string &encoded, String &decoded) {
  if (encoded.empty() || (encoded.size() & 1)) return false;
  decoded = "";
  decoded.reserve(encoded.size() / 2);
  for (size_t i = 0; i < encoded.size(); i += 2) {
    const int high = nibble(encoded[i]), low = nibble(encoded[i + 1]);
    if (high < 0 || low < 0) return false;
    decoded += static_cast<char>((high << 4) | low);
  }
  return true;
}

std::string jsonEscape(const String &value) {
  std::string output;
  output.reserve(value.length() + 8);
  for (size_t i = 0; i < value.length(); ++i) {
    const unsigned char c = value[i];
    if (c == '"' || c == '\\') { output += '\\'; output += static_cast<char>(c); }
    else if (c >= 0x20) output += static_cast<char>(c);
  }
  return output;
}

IPAddress maskForPrefix(uint8_t prefix) {
  uint8_t bytes[4] {};
  for (uint8_t bit = 0; bit < prefix; ++bit) bytes[bit / 8] |= 1U << (7 - (bit % 8));
  return IPAddress(bytes[0], bytes[1], bytes[2], bytes[3]);
}

const char *stateName(WireGuardManager::State state) {
  switch (state) {
    case WireGuardManager::State::Disabled: return "disabled";
    case WireGuardManager::State::NoConfig: return "not_configured";
    case WireGuardManager::State::WaitingWiFi: return "waiting_wifi";
    case WireGuardManager::State::SSIDBlocked: return "ssid_blocked";
    case WireGuardManager::State::WaitingTime: return "waiting_time";
    case WireGuardManager::State::CaptiveBlocked: return "captive_blocked";
    case WireGuardManager::State::Connecting: return "connecting";
    case WireGuardManager::State::Connected: return "connected";
    case WireGuardManager::State::Error: return "error";
  }
  return "error";
}

}  // namespace

void WireGuardManager::begin() {
  load();
  state_ = !configured_ ? State::NoConfig : (enabled_ ? State::WaitingWiFi : State::Disabled);
}

bool WireGuardManager::load() {
  Preferences preferences;
  if (!preferences.begin(kNamespace, true)) return false;
  const String text = preferences.getString(kConfigKey, "");
  enabled_ = preferences.getBool(kEnabledKey, false);
  restricted_ = preferences.getBool(kRestrictedKey, false);
  const size_t count = std::min(static_cast<size_t>(preferences.getUChar(kSSIDCountKey, 0)), MaxSSIDs);
  allowedSSIDs_.clear();
  for (size_t index = 0; index < count; ++index) {
    const String key = "ssid" + String(index);
    const String ssid = preferences.getString(key.c_str(), "");
    if (!ssid.isEmpty()) allowedSSIDs_.push_back(ssid);
  }
  preferences.end();
  WireGuardConfigError error;
  configured_ = !text.isEmpty() && WireGuardConfigParser::parse(text.c_str(), config_, error);
  if (!configured_ && !text.isEmpty()) {
    error_ = WireGuardConfigParser::errorCode(error);
    LOG_WARN("stored WireGuard configuration rejected code=%s", error_.c_str());
  }
  return configured_;
}

bool WireGuardManager::persist(const std::string &text, bool enabled) {
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) return false;
  const bool saved = preferences.putString(kConfigKey, text.c_str()) == text.size() &&
                     preferences.putBool(kEnabledKey, enabled) == sizeof(bool);
  preferences.end();
  return saved;
}

bool WireGuardManager::persistPolicy() {
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) return false;
  bool saved = preferences.putBool(kRestrictedKey, restricted_) == sizeof(bool) &&
               preferences.putUChar(kSSIDCountKey, static_cast<uint8_t>(allowedSSIDs_.size())) == 1;
  for (size_t index = 0; index < MaxSSIDs; ++index) {
    const String key = "ssid" + String(index);
    if (index < allowedSSIDs_.size()) {
      saved = preferences.putString(key.c_str(), allowedSSIDs_[index]) == allowedSSIDs_[index].length() && saved;
    } else {
      preferences.remove(key.c_str());
    }
  }
  preferences.end();
  return saved;
}

void WireGuardManager::setError(const char *code) {
  stop();
  error_ = code;
  state_ = State::Error;
  retryAtMs_ = millis() + 30000;
  LOG_WARN("WireGuard state error code=%s", code);
}

bool WireGuardManager::ssidAllowed(const String &ssid) const {
  if (!restricted_) return true;
  return std::find(allowedSSIDs_.begin(), allowedSSIDs_.end(), ssid) != allowedSSIDs_.end();
}

void WireGuardManager::resetAssociation() {
  stop();
  requestedTimeSync_ = false;
  timeSyncStartedMs_ = 0;
  retryAtMs_ = 0;
  error_ = "";
  captiveGateWasBlocking_ = false;
  lastCaptiveGateState_ = CaptivePortalPolicy::GateState::NotRequired;
}

void WireGuardManager::scheduleRuntimeReset() {
  // Let a management acknowledgement leave through the current tunnel before
  // a disable, replacement, or policy change tears that route down.
  runtimeResetAtMs_ = millis() + 250;
}

bool WireGuardManager::start() {
  IPAddress localIP;
  IPAddress allowedIP;
  if (!localIP.fromString(config_.address.c_str()) ||
      !allowedIP.fromString(config_.allowedIP.c_str())) {
    setError("invalid_address");
    return false;
  }

  ip_addr_t endpointIP {};
  struct addrinfo hints {};
  hints.ai_family = AF_INET;
  struct addrinfo *resolved = nullptr;
  if (lwip_getaddrinfo(config_.endpointHost.c_str(), nullptr, &hints, &resolved) != 0 || !resolved) {
    if (resolved) lwip_freeaddrinfo(resolved);
    setError("endpoint_dns");
    return false;
  }
  const struct in_addr address = reinterpret_cast<struct sockaddr_in *>(resolved->ai_addr)->sin_addr;
  inet_addr_to_ip4addr(ip_2_ip4(&endpointIP), &address);
  lwip_freeaddrinfo(resolved);
  char endpointText[IP4ADDR_STRLEN_MAX] {};
  ipaddr_ntoa_r(&endpointIP, endpointText, sizeof(endpointText));
  LOG_WIFI("WireGuard endpoint resolved host=%s ip=%s", config_.endpointHost.c_str(),
           endpointText);

  struct wireguardif_init_data init {};
  init.private_key = config_.privateKey.c_str();
  init.listen_port = config_.listenPort;

  // The custom lwIP interface has no independent route table. Using the
  // AllowedIPs mask routes exactly that range; the parser ensures the local
  // tunnel address is part of it.
  const IPAddress subnet = maskForPrefix(config_.allowedPrefix);
  const IPAddress gateway(0, 0, 0, 0);
  ip_addr_t ipaddr = IPADDR4_INIT(static_cast<uint32_t>(localIP));
  ip_addr_t netmask = IPADDR4_INIT(static_cast<uint32_t>(subnet));
  ip_addr_t gatewayAddress = IPADDR4_INIT(static_cast<uint32_t>(gateway));

  struct wireguardif_peer peer;
  wireguardif_peer_init(&peer);
  peer.public_key = config_.publicKey.c_str();
  if (!config_.presharedKey.empty()) {
    size_t decodedLength = 0;
    if (mbedtls_base64_decode(presharedKey_, sizeof(presharedKey_), &decodedLength,
                              reinterpret_cast<const unsigned char *>(config_.presharedKey.data()),
                              config_.presharedKey.size()) != 0 || decodedLength != sizeof(presharedKey_)) {
      setError("invalid_preshared_key"); return false;
    }
    peer.preshared_key = presharedKey_;
  }
  peer.endpoint_ip = endpointIP;
  peer.endport_port = config_.endpointPort;
  peer.keep_alive = config_.persistentKeepalive;
  const IPAddress allowedMask = maskForPrefix(config_.allowedPrefix);
  peer.allowed_ip = IPADDR4_INIT(static_cast<uint32_t>(allowedIP));
  peer.allowed_mask = IPADDR4_INIT(static_cast<uint32_t>(allowedMask));

  wireguard_platform_init();
  const char *startupError = nullptr;
  bool netifCreated = false;
  bool peerCreated = false;
  bool peerConnected = false;
  {
    LwipCoreLock lock;
    physicalNetif_ = netif_default;
    if (!physicalNetif_) {
      startupError = "physical_interface";
    } else {
      init.bind_netif = physicalNetif_;
      memset(&wgNetifStorage_, 0, sizeof(wgNetifStorage_));
      wgNetif_ = netif_add(&wgNetifStorage_, ip_2_ip4(&ipaddr), ip_2_ip4(&netmask),
                           ip_2_ip4(&gatewayAddress), &init, &wireguardif_init, &ip_input);
      netifCreated = wgNetif_ != nullptr;
      if (!netifCreated) {
        startupError = "interface_init";
      } else {
        wgNetif_->mtu = config_.mtu;
        netif_set_up(wgNetif_);
        peerCreated = wireguardif_add_peer(wgNetif_, &peer, &peerIndex_) == ERR_OK &&
                      peerIndex_ != WIREGUARDIF_INVALID_INDEX;
        if (!peerCreated) {
          startupError = "peer_init";
        } else {
          peerConnected = wireguardif_connect(wgNetif_, peerIndex_) == ERR_OK;
          if (!peerConnected) startupError = "peer_init";
        }
      }
    }
  }
  if (netifCreated) LOG_WIFI("WireGuard netif created mtu=%u", config_.mtu);
  if (peerCreated) LOG_WIFI("WireGuard peer created index=%u", peerIndex_);
  if (peerConnected) LOG_WIFI("WireGuard peer connect requested index=%u", peerIndex_);
  if (startupError) {
    setError(startupError);
    return false;
  }
  // The WireGuard UDP PCB is pinned to physicalNetif_. The physical interface
  // remains the default; lwIP selects this netif only for AllowedIPs.
  state_ = State::Connecting;
  tunnelStartedMs_ = millis();
  error_ = "";
  LOG_WIFI("WireGuard starting address=%s endpoint=%s:%u allowed=%s/%u ssid=%s",
           config_.address.c_str(), config_.endpointHost.c_str(), config_.endpointPort,
           config_.allowedIP.c_str(), config_.allowedPrefix, WiFi.SSID().c_str());
  return true;
}

void WireGuardManager::stop() {
  if (wgNetif_) {
    LOG_WIFI("WireGuard shutdown begin netif=%p peer=%u", wgNetif_, peerIndex_);
    {
      LwipCoreLock lock;
      if (peerIndex_ != WIREGUARDIF_INVALID_INDEX) {
        wireguardif_disconnect(wgNetif_, peerIndex_);
        wireguardif_remove_peer(wgNetif_, peerIndex_);
      }
      wireguardif_shutdown(wgNetif_);
      netif_remove(wgNetif_);
      memset(&wgNetifStorage_, 0, sizeof(wgNetifStorage_));
      wgNetif_ = nullptr;
      physicalNetif_ = nullptr;
      peerIndex_ = WIREGUARDIF_INVALID_INDEX;
    }
    LOG_WIFI("WireGuard shutdown complete");
  }
  memset(presharedKey_, 0, sizeof(presharedKey_));
  wgNetif_ = nullptr;
  physicalNetif_ = nullptr;
  peerIndex_ = WIREGUARDIF_INVALID_INDEX;
  tunnelStartedMs_ = 0;
}

void WireGuardManager::evaluate() {
  const bool stationConnected = WiFi.status() == WL_CONNECTED && WiFi.getMode() != WIFI_AP;
  const String ssid = stationConnected ? WiFi.SSID() : String();
  if (ssid != lastSSID_) {
    resetAssociation();
    lastSSID_ = ssid;
  }
  if (!configured_) { stop(); state_ = State::NoConfig; return; }
  if (!enabled_) { stop(); state_ = State::Disabled; return; }
  if (!stationConnected) { stop(); state_ = State::WaitingWiFi; return; }
  if (!ssidAllowed(ssid)) { stop(); state_ = State::SSIDBlocked; return; }
  const CaptivePortalPolicy::GateState captiveGate =
      g_captivePortalAutomation.wireGuardGateState();
  const bool captiveBlocks = CaptivePortalPolicy::blocksWireGuard(captiveGate);
  if (captiveBlocks) {
    stop();
    state_ = State::CaptiveBlocked;
    if (!captiveGateWasBlocking_) {
      LOG_WIFI("WIREGUARD blocked by captive ssid=\"%s\"", ssid.c_str());
    }
    if (captiveGate == CaptivePortalPolicy::GateState::Failed &&
        lastCaptiveGateState_ != CaptivePortalPolicy::GateState::Failed) {
      LOG_WARN("WIREGUARD remains blocked captive_result=failed");
    }
    captiveGateWasBlocking_ = true;
    lastCaptiveGateState_ = captiveGate;
    return;
  }
  if (captiveGateWasBlocking_) {
    if (captiveGate == CaptivePortalPolicy::GateState::Success) {
      LOG_WIFI("WIREGUARD captive gate released result=success");
    } else if (captiveGate ==
               CaptivePortalPolicy::GateState::AlreadyConnected) {
      LOG_WIFI("WIREGUARD captive gate released result=already_connected");
    }
  }
  captiveGateWasBlocking_ = false;
  lastCaptiveGateState_ = captiveGate;
  if (state_ == State::Error) {
    if (static_cast<int32_t>(millis() - retryAtMs_) < 0) return;
    requestedTimeSync_ = false;
    error_ = "";
  }
  if (wgNetif_) {
    bool peerUp = false;
    {
      LwipCoreLock lock;
      peerUp = wireguardif_peer_is_up(wgNetif_, peerIndex_, nullptr, nullptr) == ERR_OK;
    }
    if (peerUp) {
      state_ = State::Connected;
    } else if (millis() - tunnelStartedMs_ > 30000) {
      setError("handshake_timeout");
    } else {
      state_ = State::Connecting;
    }
    return;
  }
  if (time(nullptr) < kMinimumValidTime) {
    state_ = State::WaitingTime;
    if (!requestedTimeSync_) {
      requestedTimeSync_ = true;
      timeSyncStartedMs_ = millis();
      configTime(0, 0, "pool.ntp.org", "time.cloudflare.com", "time.google.com");
      LOG_WIFI("WireGuard waiting for secure wall-clock synchronization");
    } else if (millis() - timeSyncStartedMs_ > kTimeSyncTimeoutMs) {
      setError("time_sync");
    }
    return;
  }
  start();
}

void WireGuardManager::loop() {
  if (runtimeResetAtMs_) {
    if (static_cast<int32_t>(millis() - runtimeResetAtMs_) < 0) return;
    runtimeResetAtMs_ = 0;
    resetAssociation();
  }
  evaluate();
}

std::string WireGuardManager::statusJson() const {
  // Keep the encrypted status record within an ATT MTU of 185. The endpoint
  // has its own bounded query because it can be substantially longer.
  return std::string("{\"c\":") + (configured_ ? "true" : "false") +
      ",\"e\":" + (enabled_ ? "true" : "false") +
      ",\"s\":\"" + stateName(state_) + "\",\"ip\":\"" +
      (configured_ ? config_.address : "") + "\",\"r\":" +
      (restricted_ ? "true" : "false") + ",\"n\":" +
      std::to_string(allowedSSIDs_.size()) + ",\"x\":\"" +
      jsonEscape(error_) + "\"}";
}

uint32_t WireGuardManager::checksum(const uint8_t *data, size_t length) {
  uint32_t value = 2166136261u;
  for (size_t index = 0; index < length; ++index) value = (value ^ data[index]) * 16777619u;
  return value;
}

void WireGuardManager::writeUpload(uint64_t token, size_t offset,
                                   const uint8_t *data, size_t length,
                                   std::string &reply) {
  if (!data || length == 0 || !upload_.active || upload_.token != token ||
      offset != upload_.bytes.size() ||
      upload_.bytes.size() + length > upload_.expectedSize) {
    reply = "error wireguard_offset";
    return;
  }
  upload_.bytes.insert(upload_.bytes.end(), data, data + length);
  char tokenText[17];
  snprintf(tokenText, sizeof(tokenText), "%016llx",
           static_cast<unsigned long long>(token));
  reply = std::string("wireguard ack ") + tokenText + " " +
          std::to_string(upload_.bytes.size());
}

void WireGuardManager::addPolicySSID(const uint8_t *data, size_t length,
                                     std::string &reply) {
  if (!data || length == 0 || length > 32) {
    reply = "error wireguard_policy";
    return;
  }
  const String ssid(reinterpret_cast<const char *>(data), length);
  const bool valid = policyUploadActive_ && pendingSSIDs_.size() < MaxSSIDs &&
      std::find(pendingSSIDs_.begin(), pendingSSIDs_.end(), ssid) == pendingSSIDs_.end();
  if (!valid) reply = "error wireguard_policy";
  else { pendingSSIDs_.push_back(ssid); reply = "wireguard policy ack"; }
}

bool WireGuardManager::handleCommand(const std::string &command, std::string &reply) {
  if (command.rfind("WIREGUARD ", 0) != 0) return false;
  if (command == "WIREGUARD STATUS") { reply = statusJson(); return true; }
  if (command == "WIREGUARD PEER") {
    const std::string endpoint = configured_
        ? config_.endpointHost + ":" + std::to_string(config_.endpointPort) : "";
    reply = "{\"p\":\"" + endpoint + "\"}";
    return true;
  }
  if (command.rfind("WIREGUARD SSID ", 0) == 0 && command != "WIREGUARD SSID BEGIN") {
    unsigned long index = 0;
    if (!parseUnsigned(command.substr(15), MaxSSIDs - 1, index) || index >= allowedSSIDs_.size()) {
      reply = "error wireguard_not_found";
    } else {
      reply = "{\"ssid\":\"" + jsonEscape(allowedSSIDs_[index]) + "\"}";
    }
    return true;
  }
  if (command.rfind("WIREGUARD BEGIN ", 0) == 0) {
    const size_t first = command.find(' ', 16);
    const size_t second = first == std::string::npos ? first : command.find(' ', first + 1);
    const size_t third = second == std::string::npos ? second : command.find(' ', second + 1);
    uint64_t token = 0; unsigned long size = 0, expectedChecksum = 0, enabled = 0;
    const bool valid = first != std::string::npos && second != std::string::npos &&
        third != std::string::npos && parseToken(command.substr(16, first - 16), token) &&
        parseUnsigned(command.substr(first + 1, second - first - 1), WireGuardConfigParser::MaxConfigBytes, size) && size > 0 &&
        parseUnsigned(command.substr(second + 1, third - second - 1), 0xffffffffUL, expectedChecksum, 16) &&
        parseUnsigned(command.substr(third + 1), 1, enabled);
    if (!valid) reply = "error wireguard_invalid";
    else if (upload_.active && upload_.token != token) reply = "error wireguard_busy";
    else {
      if (!upload_.active) {
        upload_ = {}; upload_.active = true; upload_.token = token;
        upload_.expectedSize = size; upload_.expectedChecksum = static_cast<uint32_t>(expectedChecksum);
        upload_.enabled = enabled == 1; upload_.bytes.reserve(size);
      } else if (upload_.expectedSize != size || upload_.expectedChecksum != expectedChecksum || upload_.enabled != (enabled == 1)) {
        reply = "error wireguard_invalid"; return true;
      }
      char tokenText[17]; snprintf(tokenText, sizeof(tokenText), "%016llx", static_cast<unsigned long long>(token));
      reply = std::string("wireguard ready ") + tokenText + " " + std::to_string(upload_.bytes.size());
    }
    return true;
  }
  if (command.rfind("WIREGUARD DATA ", 0) == 0) {
    const size_t first = command.find(' ', 15);
    const size_t second = first == std::string::npos ? first : command.find(' ', first + 1);
    uint64_t token = 0; unsigned long offset = 0;
    const std::string hex = second == std::string::npos ? "" : command.substr(second + 1);
    bool valid = first != std::string::npos && second != std::string::npos && parseToken(command.substr(15, first - 15), token) &&
        parseUnsigned(command.substr(first + 1, second - first - 1), WireGuardConfigParser::MaxConfigBytes, offset) &&
        upload_.active && upload_.token == token && offset == upload_.bytes.size() && !hex.empty() && !(hex.size() & 1);
    std::vector<uint8_t> decoded;
    if (valid) {
      decoded.reserve(hex.size() / 2);
      for (size_t index = 0; index < hex.size(); index += 2) {
        const int high = nibble(hex[index]), low = nibble(hex[index + 1]);
        if (high < 0 || low < 0) { valid = false; break; }
        decoded.push_back(static_cast<uint8_t>((high << 4) | low));
      }
      valid = valid && upload_.bytes.size() + decoded.size() <= upload_.expectedSize;
    }
    if (!valid) reply = "error wireguard_offset";
    else writeUpload(token, offset, decoded.data(), decoded.size(), reply);
    return true;
  }
  if (command.rfind("WIREGUARD COMMIT ", 0) == 0) {
    uint64_t token = 0;
    const bool complete = parseToken(command.substr(17), token) && upload_.active && upload_.token == token &&
        upload_.bytes.size() == upload_.expectedSize && checksum(upload_.bytes.data(), upload_.bytes.size()) == upload_.expectedChecksum;
    if (!complete) { reply = "error wireguard_checksum"; return true; }
    const std::string text(upload_.bytes.begin(), upload_.bytes.end());
    WireGuardConfig parsed; WireGuardConfigError error;
    if (!WireGuardConfigParser::parse(text, parsed, error)) {
      reply = std::string("error wireguard_config_") + WireGuardConfigParser::errorCode(error);
    } else if (!persist(text, upload_.enabled)) {
      reply = "error wireguard_storage";
    } else {
      config_ = parsed; configured_ = true; enabled_ = upload_.enabled;
      requestedTimeSync_ = false; error_ = "";
      state_ = enabled_ ? State::WaitingWiFi : State::Disabled;
      scheduleRuntimeReset();
      reply = "wireguard committed";
    }
    upload_ = {};
    return true;
  }
  if (command == "WIREGUARD ABORT" || command.rfind("WIREGUARD ABORT ", 0) == 0) {
    upload_ = {};
    reply = "wireguard aborted";
    return true;
  }
  if (command == "WIREGUARD POLICY BEGIN") {
    pendingSSIDs_.clear(); pendingRestricted_ = true; policyUploadActive_ = true;
    reply = "wireguard policy ready"; return true;
  }
  if (command.rfind("WIREGUARD POLICY ADD ", 0) == 0) {
    String ssid;
    if (!decodeHex(command.substr(21), ssid)) reply = "error wireguard_policy";
    else addPolicySSID(reinterpret_cast<const uint8_t *>(ssid.c_str()), ssid.length(), reply);
    return true;
  }
  if (command == "WIREGUARD POLICY ANY") {
    pendingSSIDs_.clear(); pendingRestricted_ = false; policyUploadActive_ = true;
    reply = "wireguard policy ready"; return true;
  }
  if (command == "WIREGUARD POLICY COMMIT") {
    if (!policyUploadActive_ || (pendingRestricted_ && pendingSSIDs_.empty())) reply = "error wireguard_policy";
    else {
      const bool previousRestricted = restricted_; const auto previousSSIDs = allowedSSIDs_;
      restricted_ = pendingRestricted_; allowedSSIDs_ = pendingSSIDs_;
      if (!persistPolicy()) { restricted_ = previousRestricted; allowedSSIDs_ = previousSSIDs; reply = "error wireguard_storage"; }
      else { scheduleRuntimeReset(); reply = "wireguard policy committed"; }
    }
    policyUploadActive_ = false; pendingSSIDs_.clear();
    return true;
  }
  if (command == "WIREGUARD ENABLE 0" || command == "WIREGUARD ENABLE 1") {
    if (!configured_) reply = "error wireguard_not_found";
    else {
      const bool next = command.back() == '1';
      Preferences preferences;
      if (!preferences.begin(kNamespace, false) || preferences.putBool(kEnabledKey, next) != sizeof(bool)) reply = "error wireguard_storage";
      else { enabled_ = next; scheduleRuntimeReset(); reply = "wireguard enabled"; }
      preferences.end();
    }
    return true;
  }
  if (command == "WIREGUARD REMOVE") {
    Preferences preferences;
    const bool opened = preferences.begin(kNamespace, false);
    const bool removed = opened && preferences.clear();
    if (opened) preferences.end();
    if (!removed) reply = "error wireguard_storage";
    else {
      config_ = {}; configured_ = false; enabled_ = false; restricted_ = false;
      allowedSSIDs_.clear(); state_ = State::NoConfig; error_ = "";
      scheduleRuntimeReset();
      reply = "wireguard removed";
    }
    return true;
  }
  reply = "error wireguard_invalid";
  return true;
}

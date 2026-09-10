#include "CaptivePortalAutomation.h"

#include <HTTPClient.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <algorithm>
#include <cctype>
#include <map>
#include <vector>

extern "C" {
#include <lwip/netdb.h>
#include <lwip/sockets.h>
}

#include "CaptivePortalParsing.h"
#include "Logging.h"
#include "WireGuardManager.h"

CaptivePortalAutomation g_captivePortalAutomation;

namespace {

constexpr const char *kNamespace = "captive";
constexpr size_t kMaxResponseBytes = 32 * 1024;
constexpr size_t kMaxSteps = 200;
constexpr uint32_t kMaxWaitMs = 60000;
constexpr size_t kMaxCapturedBytes = 1024;
constexpr size_t kMaxRequestURLBytes = 2048;
constexpr size_t kMaxRequestBodyBytes = 4096;
constexpr size_t kMaxHeaders = 16;

String key(const char *prefix, size_t index) {
  return String(prefix) + String(index);
}

String trimmed(const String &value) {
  String result = value;
  result.trim();
  return result;
}

String jsonEscape(const String &value) {
  String result;
  result.reserve(value.length() + 8);
  for (size_t i = 0; i < value.length(); ++i) {
    const char c = value[i];
    switch (c) {
      case '\"': result += "\\\""; break;
      case '\\': result += "\\\\"; break;
      case '\n': result += "\\n"; break;
      case '\r': result += "\\r"; break;
      case '\t': result += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) >= 0x20) result += c;
    }
  }
  return result;
}

String boundedStatusText(const String &value, size_t maximumBytes) {
  String result;
  result.reserve(std::min(value.length(), maximumBytes));
  for (size_t i = 0; i < value.length() && result.length() < maximumBytes;) {
    const unsigned char c = static_cast<unsigned char>(value[i]);
    // Keep CAPTIVE STATUS small enough for one encrypted BLE notification and
    // prevent JSON escaping from multiplying an attacker-controlled message.
    if (c < 0x20 || c == '\"' || c == '\\') {
      result += '?';
      ++i;
      continue;
    }
    if (c < 0x80) {
      result += static_cast<char>(c);
      ++i;
      continue;
    }
    const size_t sequenceLength = (c & 0xe0) == 0xc0 ? 2 :
                                  (c & 0xf0) == 0xe0 ? 3 :
                                  (c & 0xf8) == 0xf0 ? 4 : 0;
    bool valid = sequenceLength > 0 && i + sequenceLength <= value.length() &&
                 result.length() + sequenceLength <= maximumBytes;
    for (size_t j = 1; valid && j < sequenceLength; ++j)
      valid = (static_cast<unsigned char>(value[i + j]) & 0xc0) == 0x80;
    if (!valid) {
      if (result.length() < maximumBytes) result += '?';
      ++i;
      continue;
    }
    result.concat(value.c_str() + i, sequenceLength);
    i += sequenceLength;
  }
  return result;
}

bool parseUnsigned(const std::string &text, unsigned long &value, int base = 10) {
  if (text.empty()) return false;
  char *end = nullptr;
  value = strtoul(text.c_str(), &end, base);
  return end && *end == '\0';
}

bool parseToken(const std::string &text, uint64_t &value) {
  if (text.empty() || text.size() > 16) return false;
  char *end = nullptr;
  value = strtoull(text.c_str(), &end, 16);
  return end && *end == '\0' && value != 0;
}

int nibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

bool decodeHex(const std::string &value, String &result) {
  if (value.empty() || (value.size() & 1)) return false;
  result = "";
  result.reserve(value.size() / 2);
  for (size_t i = 0; i < value.size(); i += 2) {
    const int high = nibble(value[i]);
    const int low = nibble(value[i + 1]);
    if (high < 0 || low < 0) return false;
    result += static_cast<char>((high << 4) | low);
  }
  return true;
}

String encodeHex(const String &value) {
  static const char digits[] = "0123456789abcdef";
  String result;
  result.reserve(value.length() * 2);
  for (size_t i = 0; i < value.length(); ++i) {
    const uint8_t byte = static_cast<uint8_t>(value[i]);
    result += digits[byte >> 4];
    result += digits[byte & 0x0f];
  }
  return result;
}

String urlEncode(const String &value) {
  static const char digits[] = "0123456789ABCDEF";
  String result;
  for (size_t i = 0; i < value.length(); ++i) {
    const uint8_t c = static_cast<uint8_t>(value[i]);
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
      result += static_cast<char>(c);
    } else {
      result += '%';
      result += digits[c >> 4];
      result += digits[c & 0x0f];
    }
  }
  return result;
}

String origin(const String &url) {
  const int scheme = url.indexOf("://");
  if (scheme < 0) return "";
  const int slash = url.indexOf('/', scheme + 3);
  return slash < 0 ? url : url.substring(0, slash);
}

String host(const String &url) {
  const String base = origin(url);
  const int scheme = base.indexOf("://");
  if (scheme < 0) return "";
  String value = base.substring(scheme + 3);
  const int colon = value.lastIndexOf(':');
  if (colon > 0 && value.indexOf(']') < 0) value = value.substring(0, colon);
  value.toLowerCase();
  return value;
}

String resolveURL(const String &base, const String &location) {
  if (location.startsWith("http://") || location.startsWith("https://")) return location;
  const int schemeEnd = base.indexOf("://");
  if (location.startsWith("//") && schemeEnd > 0)
    return base.substring(0, schemeEnd) + ":" + location;
  const String baseOrigin = origin(base);
  if (location.startsWith("/")) return baseOrigin + location;
  const int query = base.indexOf('?');
  const String withoutQuery = query < 0 ? base : base.substring(0, query);
  const int slash = withoutQuery.lastIndexOf('/');
  return (slash > schemeEnd + 2 ? withoutQuery.substring(0, slash + 1)
                                : baseOrigin + "/") + location;
}

String expand(const String &input, const std::map<std::string, String> &variables,
              bool &ok) {
  String result;
  size_t cursor = 0;
  ok = true;
  while (cursor < input.length()) {
    const int start = input.indexOf("${", cursor);
    if (start < 0) {
      result += input.substring(cursor);
      break;
    }
    result += input.substring(cursor, start);
    const int end = input.indexOf('}', start + 2);
    if (end < 0) { ok = false; return ""; }
    String name = input.substring(start + 2, end);
    bool encoded = false;
    if (name.startsWith("url:")) { encoded = true; name.remove(0, 4); }
    const auto found = variables.find(std::string(name.c_str()));
    if (found == variables.end()) { ok = false; return ""; }
    result += encoded ? urlEncode(found->second) : found->second;
    cursor = static_cast<size_t>(end + 1);
  }
  return result;
}

struct HTTPResult {
  int status = 0;
  String body;
  String finalURL;
  String error;
};

bool resolveIPv4(const String &hostname, IPAddress &address) {
  struct addrinfo hints {};
  hints.ai_family = CaptivePortalPolicy::resolverFamily(
      CaptivePortalPolicy::AddressFamily::IPv4);
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *resolved = nullptr;
  const int error = lwip_getaddrinfo(hostname.c_str(), nullptr, &hints, &resolved);
  if (error != 0 || !resolved || resolved->ai_family != AF_INET ||
      resolved->ai_addrlen < sizeof(struct sockaddr_in)) {
    if (resolved) lwip_freeaddrinfo(resolved);
    LOG_WARN("CAPTIVE DNS failed host=%s error=%d", hostname.c_str(), error);
    return false;
  }
  const auto *socketAddress =
      reinterpret_cast<const struct sockaddr_in *>(resolved->ai_addr);
  address = IPAddress(reinterpret_cast<const uint8_t *>(&socketAddress->sin_addr));
  lwip_freeaddrinfo(resolved);
  LOG_WIFI("CAPTIVE DNS host=%s resolved=%s", hostname.c_str(),
           address.toString().c_str());
  return true;
}

class ResolvedIPv4Client final : public WiFiClient {
 public:
  explicit ResolvedIPv4Client(const IPAddress &address) : address_(address) {}

  int connect(const char *hostname, uint16_t port, int32_t timeout) override {
    LOG_WIFI("CAPTIVE TCP ip=%s port=%u", address_.toString().c_str(), port);
    const int connected = WiFiClient::connect(address_, port, timeout);
    if (!connected) {
      LOG_WARN("CAPTIVE TCP failed host=%s ip=%s port=%u", hostname,
               address_.toString().c_str(), port);
    }
    return connected;
  }

 private:
  IPAddress address_;
};

class ResolvedIPv4SecureClient final : public WiFiClientSecure {
 public:
  explicit ResolvedIPv4SecureClient(const IPAddress &address) : address_(address) {}

  int connect(const char *hostname, uint16_t port, int32_t timeout) override {
    _timeout = timeout;
    LOG_WIFI("CAPTIVE TCP ip=%s port=%u", address_.toString().c_str(), port);
    // Connect the socket to the selected IPv4 address while retaining the
    // original hostname for TLS SNI. Captive HTTPS remains intentionally
    // certificate-insecure, as configured by setInsecure() below.
    const int connected = WiFiClientSecure::connect(
        address_, port, hostname, nullptr, nullptr, nullptr);
    if (!connected) {
      LOG_WARN("CAPTIVE TCP failed host=%s ip=%s port=%u", hostname,
               address_.toString().c_str(), port);
    }
    return connected;
  }

 private:
  IPAddress address_;
};

class BoundedResponseStream final : public Stream {
 public:
  explicit BoundedResponseStream(size_t limit) : limit_(limit) {
    value_.reserve(std::min<size_t>(limit, 4096));
  }
  size_t write(uint8_t byte) override { return write(&byte, 1); }
  size_t write(const uint8_t *buffer, size_t size) override {
    const size_t available = value_.length() < limit_ ? limit_ - value_.length() : 0;
    const size_t accepted = std::min(size, available);
    if (accepted) value_.concat(reinterpret_cast<const char *>(buffer), accepted);
    if (accepted != size) overflow_ = true;
    return accepted;
  }
  int available() override { return 0; }
  int read() override { return -1; }
  int peek() override { return -1; }
  void flush() override {}
  bool overflowed() const { return overflow_; }
  const String &value() const { return value_; }

 private:
  size_t limit_;
  bool overflow_ = false;
  String value_;
};

HTTPResult performRequest(const String &method, String url, const String &body,
                          const String &contentType,
                          const std::map<std::string, String> &headers,
                          const String &requiredHostSuffix, CookieJar &cookies,
                          CaptivePortalPolicy::AddressFamily addressFamily) {
  HTTPResult result;
  String currentMethod = method;
  String currentBody = body;
  String currentContentType = contentType;
  for (int redirects = 0; redirects <= 10; ++redirects) {
    const String currentHost = host(url);
    if (requiredHostSuffix.length()) {
      if (!currentHost.endsWith(requiredHostSuffix) ||
          currentHost.length() <= requiredHostSuffix.length()) {
        result.error = "UNTRUSTED_HOST";
        return result;
      }
    }
    HTTPClient http;
    WiFiClient plain;
    WiFiClientSecure secure;
    IPAddress resolvedAddress;
    if (addressFamily == CaptivePortalPolicy::AddressFamily::IPv4 &&
        !resolveIPv4(currentHost, resolvedAddress)) {
      result.error = "NETWORK:DNS failed";
      return result;
    }
    ResolvedIPv4Client ipv4Plain(resolvedAddress);
    ResolvedIPv4SecureClient ipv4Secure(resolvedAddress);
    secure.setInsecure();  // Captive portals are reached before normal PKI is reliable.
    ipv4Secure.setInsecure();
    const bool https = url.startsWith("https://");
    NetworkClient *client = nullptr;
    if (https) {
      client = addressFamily == CaptivePortalPolicy::AddressFamily::IPv4
                   ? static_cast<NetworkClient *>(&ipv4Secure)
                   : static_cast<NetworkClient *>(&secure);
    } else {
      client = addressFamily == CaptivePortalPolicy::AddressFamily::IPv4
                   ? static_cast<NetworkClient *>(&ipv4Plain)
                   : static_cast<NetworkClient *>(&plain);
    }
    LOG_WIFI("CAPTIVE HTTP method=%s host=%s family=%s", currentMethod.c_str(),
             currentHost.c_str(),
             CaptivePortalPolicy::addressFamilyName(addressFamily));
    if (!http.begin(*client, url)) {
      result.error = "HTTP_INIT";
      return result;
    }
    http.setConnectTimeout(10000);
    http.setTimeout(20000);
    // Arduino-ESP32 deliberately ignores User-Agent passed to addHeader(); use
    // its dedicated field so a workflow override replaces the default exactly.
    String userAgent = String("InputPilot/") + FW_VERSION + " CaptivePortal";
    for (const auto &header : headers) {
      const String name(header.first.c_str());
      if (name.equalsIgnoreCase("User-Agent")) userAgent = header.second;
    }
    http.setUserAgent(userAgent);
    http.setCookieJar(&cookies);
    const char *keys[] = {"Location"};
    http.collectHeaders(keys, 1);
    for (const auto &header : headers) {
      const String name(header.first.c_str());
      if (!name.equalsIgnoreCase("User-Agent"))
        http.addHeader(header.first.c_str(), header.second);
    }
    int status = 0;
    if (currentMethod == "GET") status = http.GET();
    else {
      http.addHeader("Content-Type", currentContentType);
      status = http.POST(currentBody);
    }
    if (status <= 0) {
      result.error = String("NETWORK:") + HTTPClient::errorToString(status);
      http.end();
      return result;
    }
    LOG_WIFI("CAPTIVE HTTP status=%d", status);
    const String location = http.header("Location");
    if (status >= 300 && status < 400 && location.length()) {
      const String next = resolveURL(url, location);
      http.end();
      // Match conventional HTTP client behavior: 301/302/303 turn a POST into
      // a GET, while 307/308 explicitly retain the method and request body.
      if (currentMethod == "POST" &&
          (status == 301 || status == 302 || status == 303)) {
        currentMethod = "GET";
        currentBody = "";
        currentContentType = "";
      }
      url = next;
      continue;
    }
    result.status = status;
    result.finalURL = url;
    if (http.getSize() > static_cast<int>(kMaxResponseBytes)) {
      result.error = "RESPONSE_TOO_LARGE";
      http.end();
      return result;
    }
    BoundedResponseStream response(kMaxResponseBytes);
    const int written = http.writeToStream(&response);
    if (response.overflowed()) {
      result.error = "RESPONSE_TOO_LARGE";
    } else if (written < 0) {
      result.error = String("NETWORK:") + HTTPClient::errorToString(written);
    } else {
      result.body = response.value();
    }
    http.end();
    return result;
  }
  result.error = "TOO_MANY_REDIRECTS";
  return result;
}

std::vector<String> lines(const String &script) {
  std::vector<String> result;
  size_t cursor = 0;
  while (cursor <= script.length()) {
    const int newline = script.indexOf('\n', cursor);
    String line = newline < 0 ? script.substring(cursor) : script.substring(cursor, newline);
    if (line.endsWith("\r")) line.remove(line.length() - 1);
    result.push_back(line);
    if (newline < 0) break;
    cursor = static_cast<size_t>(newline + 1);
  }
  return result;
}

}  // namespace

void CaptivePortalAutomation::begin() {
  mutex_ = xSemaphoreCreateMutex();
  setStatus(State::Idle, "", "No captive portal automation has run yet.");
}

bool CaptivePortalAutomation::blocksWireGuard() const {
  if (mutex_) xSemaphoreTake(mutex_, portMAX_DELAY);
  const bool blocked = wireGuardGate_.blocksWireGuard();
  if (mutex_) xSemaphoreGive(mutex_);
  return blocked;
}

CaptivePortalPolicy::GateState
CaptivePortalAutomation::wireGuardGateState() const {
  if (mutex_) xSemaphoreTake(mutex_, portMAX_DELAY);
  const CaptivePortalPolicy::GateState state = wireGuardGate_.state();
  if (mutex_) xSemaphoreGive(mutex_);
  return state;
}

void CaptivePortalAutomation::associateGate(const String &ssid,
                                             bool enabledScript) {
  if (mutex_) xSemaphoreTake(mutex_, portMAX_DELAY);
  wireGuardGate_.associate(ssid.c_str(), enabledScript);
  if (mutex_) xSemaphoreGive(mutex_);
}

void CaptivePortalAutomation::disconnectGate() {
  if (mutex_) xSemaphoreTake(mutex_, portMAX_DELAY);
  wireGuardGate_.disconnect();
  if (mutex_) xSemaphoreGive(mutex_);
}

void CaptivePortalAutomation::startGate(const String &ssid) {
  if (mutex_) xSemaphoreTake(mutex_, portMAX_DELAY);
  wireGuardGate_.start(ssid.c_str());
  if (mutex_) xSemaphoreGive(mutex_);
}

void CaptivePortalAutomation::finishGate(
    const String &ssid, CaptivePortalPolicy::GateState result) {
  if (mutex_) xSemaphoreTake(mutex_, portMAX_DELAY);
  wireGuardGate_.finish(ssid.c_str(), result);
  if (mutex_) xSemaphoreGive(mutex_);
}

size_t CaptivePortalAutomation::count() const {
  Preferences preferences;
  if (!preferences.begin(kNamespace, true)) return 0;
  const size_t result = std::min(static_cast<size_t>(preferences.getUChar("count", 0)), MaxScripts);
  preferences.end();
  return result;
}

bool CaptivePortalAutomation::load(size_t index, ScriptRecord &record) const {
  Preferences preferences;
  if (!preferences.begin(kNamespace, true)) return false;
  const size_t stored = std::min(static_cast<size_t>(preferences.getUChar("count", 0)), MaxScripts);
  if (index >= stored) { preferences.end(); return false; }
  record.ssid = preferences.getString(key("ssid", index).c_str(), "");
  record.script = preferences.getString(key("body", index).c_str(), "");
  record.delayMs = preferences.getUInt(key("delay", index).c_str(), 4000);
  record.enabled = preferences.getBool(key("enabled", index).c_str(), true);
  preferences.end();
  return record.ssid.length() > 0 && record.script.length() > 0;
}

int CaptivePortalAutomation::find(const String &ssid) const {
  ScriptRecord record;
  for (size_t i = 0; i < count(); ++i)
    if (load(i, record) && record.ssid == ssid) return static_cast<int>(i);
  return -1;
}

bool CaptivePortalAutomation::save(const ScriptRecord &record) {
  std::vector<ScriptRecord> records;
  ScriptRecord existing;
  bool replaced = false;
  for (size_t i = 0; i < count(); ++i) {
    if (!load(i, existing)) continue;
    if (existing.ssid == record.ssid) { records.push_back(record); replaced = true; }
    else records.push_back(existing);
  }
  if (!replaced) {
    if (records.size() >= MaxScripts) return false;
    records.push_back(record);
  }
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) return false;
  bool ok = true;
  for (size_t i = 0; i < MaxScripts; ++i) {
    if (i < records.size()) {
      ok = ok && preferences.putString(key("ssid", i).c_str(), records[i].ssid) > 0;
      ok = ok && preferences.putString(key("body", i).c_str(), records[i].script) > 0;
      preferences.putUInt(key("delay", i).c_str(), records[i].delayMs);
      preferences.putBool(key("enabled", i).c_str(), records[i].enabled);
    } else {
      preferences.remove(key("ssid", i).c_str());
      preferences.remove(key("body", i).c_str());
      preferences.remove(key("delay", i).c_str());
      preferences.remove(key("enabled", i).c_str());
    }
  }
  preferences.putUChar("count", static_cast<uint8_t>(records.size()));
  preferences.end();
  return ok;
}

bool CaptivePortalAutomation::remove(const String &ssid) {
  std::vector<ScriptRecord> records;
  ScriptRecord record;
  bool found = false;
  for (size_t i = 0; i < count(); ++i) {
    if (!load(i, record)) continue;
    if (record.ssid == ssid) found = true;
    else records.push_back(record);
  }
  if (!found) return false;
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) return false;
  for (size_t i = 0; i < MaxScripts; ++i) {
    if (i < records.size()) {
      preferences.putString(key("ssid", i).c_str(), records[i].ssid);
      preferences.putString(key("body", i).c_str(), records[i].script);
      preferences.putUInt(key("delay", i).c_str(), records[i].delayMs);
      preferences.putBool(key("enabled", i).c_str(), records[i].enabled);
    } else {
      preferences.remove(key("ssid", i).c_str());
      preferences.remove(key("body", i).c_str());
      preferences.remove(key("delay", i).c_str());
      preferences.remove(key("enabled", i).c_str());
    }
  }
  preferences.putUChar("count", static_cast<uint8_t>(records.size()));
  preferences.end();
  return true;
}

uint32_t CaptivePortalAutomation::checksum(const uint8_t *data, size_t length) {
  uint32_t value = 2166136261u;
  for (size_t i = 0; i < length; ++i) value = (value ^ data[i]) * 16777619u;
  return value;
}

void CaptivePortalAutomation::setStatus(State state, const String &ssid,
                                         const String &message, const String &error) {
  if (mutex_) xSemaphoreTake(mutex_, portMAX_DELAY);
  state_ = state;
  statusSSID_ = boundedStatusText(ssid, 32);
  statusMessage_ = boundedStatusText(message, 40);
  statusError_ = boundedStatusText(error, 24);
  if (state == State::Success || state == State::AlreadyConnected || state == State::Failed)
    lastRunMs_ = millis();
  if (mutex_) xSemaphoreGive(mutex_);
}

std::string CaptivePortalAutomation::statusJson() {
  if (mutex_) xSemaphoreTake(mutex_, portMAX_DELAY);
  const char *state = "idle";
  switch (state_) {
    case State::Waiting: state = "waiting"; break;
    case State::Running: state = "running"; break;
    case State::Success: state = "success"; break;
    case State::AlreadyConnected: state = "already_connected"; break;
    case State::Failed: state = "failed"; break;
    case State::Idle: break;
  }
  // Compact keys keep the worst-case encrypted payload within an ATT MTU of
  // 185 while the app maps them back to descriptive model properties.
  const String result = String("{\"s\":\"") + state + "\",\"n\":\"" +
      jsonEscape(statusSSID_) + "\",\"m\":\"" + jsonEscape(statusMessage_) +
      "\",\"e\":\"" + jsonEscape(statusError_) + "\",\"t\":" +
      String(lastRunMs_) + "}";
  if (mutex_) xSemaphoreGive(mutex_);
  return std::string(result.c_str());
}

bool CaptivePortalAutomation::startForSSID(const String &ssid, bool manual) {
  if (running_.exchange(true)) return false;
  const int index = find(ssid);
  ScriptRecord record;
  if (index < 0 || !load(index, record) || (!record.enabled && !manual)) {
    running_.store(false);
    return false;
  }
  pendingSSID_ = ssid;
  taskSSID_ = ssid;
  if (manual) ranForCurrentConnection_ = true;
  startGate(ssid);
  if (manual && g_wireGuardManager.active()) {
    LOG_WIFI("WIREGUARD stopping for manual captive run ssid=\"%s\"", ssid.c_str());
    g_wireGuardManager.stop();
  }
  setStatus(State::Running, ssid, manual ? "Manual run started." : "Captive portal script started.");
  if (xTaskCreatePinnedToCore(taskEntry, "captive-http", 10240, this, 1, nullptr, 0) != pdPASS) {
    running_.store(false);
    finishGate(ssid, CaptivePortalPolicy::GateState::Failed);
    setStatus(State::Failed, ssid, "Could not start captive portal task.", "TASK_START");
    return false;
  }
  return true;
}

void CaptivePortalAutomation::taskEntry(void *context) {
  static_cast<CaptivePortalAutomation *>(context)->runTask();
}

void CaptivePortalAutomation::runTask() {
  const String ssid = taskSSID_;
  ScriptRecord record;
  const int index = find(ssid);
  if (index < 0 || !load(index, record))
    setStatus(State::Failed, ssid, "The configured script is no longer available.", "NOT_FOUND");
  else run(record);
  if (index < 0 || record.ssid.isEmpty())
    finishGate(ssid, CaptivePortalPolicy::GateState::Failed);
  running_.store(false);
  vTaskDelete(nullptr);
}

void CaptivePortalAutomation::run(const ScriptRecord &record) {
  const std::vector<String> program = lines(record.script);
  std::map<std::string, size_t> labels;
  for (size_t i = 0; i < program.size(); ++i) {
    const String line = trimmed(program[i]);
    if (line.startsWith("LABEL ")) labels[std::string(trimmed(line.substring(6)).c_str())] = i;
  }
  std::map<std::string, String> variables;
  variables["SSID"] = record.ssid;
  std::map<std::string, String> headers;
  String requiredHostSuffix;
  CaptivePortalPolicy::AddressFamily addressFamily =
      CaptivePortalPolicy::AddressFamily::Auto;
  CookieJar cookies;
  HTTPResult last;
  size_t pc = 0;
  size_t steps = 0;
  auto fail = [&](const String &code, const String &message) {
    LOG_WARN("captive ssid=\"%s\" error=%s", record.ssid.c_str(), code.c_str());
    finishGate(record.ssid, CaptivePortalPolicy::GateState::Failed);
    setStatus(State::Failed, record.ssid, message, code);
  };
  auto jump = [&](const String &name) -> bool {
    const auto found = labels.find(std::string(trimmed(name).c_str()));
    if (found == labels.end()) { fail("UNKNOWN_LABEL", "The script references an unknown label."); return false; }
    pc = found->second;
    return true;
  };

  while (pc < program.size() && ++steps <= kMaxSteps) {
    if (WiFi.status() != WL_CONNECTED || WiFi.SSID() != record.ssid) {
      fail("WIFI_LOST", "The Wi-Fi connection was lost while the script was running.");
      return;
    }
    String line = trimmed(program[pc++]);
    if (!line.length() || line.startsWith("#") || line == "INPUTPILOT-CAPTIVE/1" ||
        line.startsWith("LABEL ")) continue;

    if (line.startsWith("ADDRESS_FAMILY ")) {
      const std::string value(trimmed(line.substring(15)).c_str());
      if (!CaptivePortalPolicy::parseAddressFamily(value, addressFamily)) {
        fail("INVALID_ADDRESS_FAMILY", "ADDRESS_FAMILY must be AUTO or IPV4.");
        return;
      }
      continue;
    }

    if (line.startsWith("WAIT ")) {
      const uint32_t duration = static_cast<uint32_t>(line.substring(5).toInt());
      if (duration > kMaxWaitMs) { fail("INVALID_WAIT", "WAIT is limited to 60000 ms."); return; }
      delay(duration);
      continue;
    }
    if (line.startsWith("HEADER ")) {
      const String field = line.substring(7);
      const int separator = field.indexOf(':');
      if (separator <= 0) { fail("INVALID_HEADER", "HEADER requires 'Name: value'."); return; }
      const String name = trimmed(field.substring(0, separator));
      bool validName = name.length() > 0 && name.length() <= 64;
      for (size_t i = 0; validName && i < name.length(); ++i) {
        const char c = name[i];
        validName = isalnum(static_cast<unsigned char>(c)) || c == '!' || c == '#' ||
                    c == '$' || c == '%' || c == '&' || c == '\'' || c == '*' ||
                    c == '+' || c == '-' || c == '.' || c == '^' || c == '_' ||
                    c == '`' || c == '|' || c == '~';
      }
      if (!validName || (headers.find(std::string(name.c_str())) == headers.end() &&
                                 headers.size() >= kMaxHeaders)) {
        fail(validName ? "TOO_MANY_HEADERS" : "INVALID_HEADER",
             validName ? "The script exceeds the request header limit."
                       : "A request header name is invalid."); return;
      }
      headers[std::string(name.c_str())] = trimmed(field.substring(separator + 1));
      continue;
    }
    if (line.startsWith("GET ") || line.startsWith("POST_FORM ") || line.startsWith("POST_JSON ")) {
      String method = "GET";
      String contentType;
      String payload;
      String target;
      if (line.startsWith("GET ")) target = line.substring(4);
      else {
        method = "POST";
        const int firstSpace = line.indexOf(' ', line.startsWith("POST_FORM ") ? 10 : 10);
        if (firstSpace < 0) { fail("INVALID_POST", "POST requires a URL and body."); return; }
        target = line.substring(10, firstSpace);
        payload = line.substring(firstSpace + 1);
        contentType = line.startsWith("POST_FORM ")
            ? "application/x-www-form-urlencoded; charset=UTF-8" : "application/json";
      }
      bool ok = false;
      target = expand(target, variables, ok);
      if (!ok || target.length() > kMaxRequestURLBytes ||
          !(target.startsWith("http://") || target.startsWith("https://"))) {
        fail("INVALID_URL", "A URL is invalid or references a missing variable."); return;
      }
      if (method == "POST") {
        payload = expand(payload, variables, ok);
        if (!ok || payload.length() > kMaxRequestBodyBytes) {
          fail(ok ? "REQUEST_TOO_LARGE" : "MISSING_VARIABLE",
               ok ? "The request body exceeds the size limit."
                  : "The request body references a missing variable."); return;
        }
      }
      std::map<std::string, String> expandedHeaders;
      for (const auto &header : headers) {
        expandedHeaders[header.first] = expand(header.second, variables, ok);
        if (!ok) { fail("MISSING_VARIABLE", "A header references a missing variable."); return; }
        if (expandedHeaders[header.first].indexOf('\r') >= 0 ||
            expandedHeaders[header.first].indexOf('\n') >= 0) {
          fail("INVALID_HEADER", "An expanded request header is invalid."); return;
        }
        if (expandedHeaders[header.first].length() > 512) {
          fail("HEADER_TOO_LARGE", "An expanded header exceeds the size limit."); return;
        }
      }
      last = performRequest(method, target, payload, contentType, expandedHeaders,
                            requiredHostSuffix, cookies, addressFamily);
      if (last.error.length()) { fail(last.error, "A captive portal network request failed."); return; }
      variables["URL"] = last.finalURL;
      variables["STATUS"] = String(last.status);
      continue;
    }
    if (line.startsWith("EXPECT_STATUS ")) {
      if (last.status != line.substring(14).toInt()) { fail("UNEXPECTED_STATUS", "The portal returned an unexpected HTTP status."); return; }
      continue;
    }
    if (line.startsWith("EXPECT_BODY ")) {
      bool ok = false;
      const String expected = expand(line.substring(12), variables, ok);
      if (!ok || last.body.indexOf(expected) < 0) { fail("UNEXPECTED_BODY", "The expected portal response was not found."); return; }
      continue;
    }
    if (line.startsWith("REQUIRE_HOST_SUFFIX ")) {
      String suffix = trimmed(line.substring(20)); suffix.toLowerCase();
      const String currentHost = host(last.finalURL);
      if (!suffix.startsWith(".") || !currentHost.endsWith(suffix) ||
          currentHost.length() <= suffix.length()) {
        fail("UNTRUSTED_HOST", "The detected portal host is not permitted by the script."); return;
      }
      // Once established, keep every later request and redirect inside the
      // allow-listed domain so a 307/308 cannot forward credentials elsewhere.
      requiredHostSuffix = suffix;
      continue;
    }
    if (line.startsWith("SET_ORIGIN ")) {
      const String name = trimmed(line.substring(11));
      const String value = origin(last.finalURL);
      if (!name.length() || !value.length()) { fail("NO_ORIGIN", "Could not derive a portal origin."); return; }
      variables[std::string(name.c_str())] = value;
      continue;
    }
    if (line.startsWith("CAPTURE_JSON ")) {
      const String args = trimmed(line.substring(13));
      const int separator = args.indexOf(' ');
      std::string value;
      const auto result = separator <= 0 ? CaptivePortalParsing::CaptureResult::Malformed
          : CaptivePortalParsing::captureJsonScalar(
                last.body.c_str(), last.body.length(),
                std::string(trimmed(args.substring(separator + 1)).c_str()),
                kMaxCapturedBytes, value);
      if (result == CaptivePortalParsing::CaptureResult::TooLarge) {
        fail("CAPTURE_TOO_LARGE", "A captured JSON value is too large."); return;
      }
      if (result != CaptivePortalParsing::CaptureResult::Found) {
        fail("JSON_VALUE_MISSING", "A required JSON value is missing."); return;
      }
      variables[std::string(args.substring(0, separator).c_str())] = String(value.c_str());
      continue;
    }
    if (line.startsWith("CAPTURE_JSON_FIRST ")) {
      const String args = trimmed(line.substring(19));
      const int nameEnd = args.indexOf(' ');
      if (nameEnd <= 0) {
        fail("INVALID_CAPTURE", "CAPTURE_JSON_FIRST requires a name and paths."); return;
      }
      const String name = args.substring(0, nameEnd);
      const String pathList = trimmed(args.substring(nameEnd + 1));
      std::vector<std::string> paths;
      size_t cursor = 0;
      bool valid = CaptivePortalParsing::isSimpleName(std::string(name.c_str()));
      while (valid && cursor <= pathList.length()) {
        const int delimiter = pathList.indexOf(" || ", cursor);
        const String path = trimmed(delimiter < 0 ? pathList.substring(cursor)
                                                  : pathList.substring(cursor, delimiter));
        const std::string pathText(path.c_str());
        if (!CaptivePortalParsing::isDotPath(pathText)) { valid = false; break; }
        paths.push_back(pathText);
        if (delimiter < 0) break;
        cursor = static_cast<size_t>(delimiter + 4);
      }
      if (!valid || paths.empty()) {
        fail("INVALID_CAPTURE", "CAPTURE_JSON_FIRST has an invalid name or path."); return;
      }
      std::string captured;
      const auto result = CaptivePortalParsing::captureFirstJsonScalar(
          last.body.c_str(), last.body.length(), paths, kMaxCapturedBytes, captured);
      if (result == CaptivePortalParsing::CaptureResult::TooLarge) {
        fail("CAPTURE_TOO_LARGE", "A captured JSON value is too large."); return;
      }
      if (result != CaptivePortalParsing::CaptureResult::Found) {
        fail("JSON_VALUE_MISSING", "A required JSON value is missing."); return;
      }
      variables[std::string(name.c_str())] = String(captured.c_str());
      continue;
    }
    if (line.startsWith("CAPTURE_OBJECT_STRING ")) {
      const String args = trimmed(line.substring(22));
      const int separator = args.indexOf(' ');
      const String name = separator < 0 ? String() : args.substring(0, separator);
      const String objectKey = separator < 0 ? String() : trimmed(args.substring(separator + 1));
      if (!CaptivePortalParsing::isSimpleName(std::string(name.c_str())) ||
          !CaptivePortalParsing::isSimpleName(std::string(objectKey.c_str()))) {
        fail("INVALID_CAPTURE", "CAPTURE_OBJECT_STRING requires a valid name and key."); return;
      }
      std::string captured;
      const auto result = CaptivePortalParsing::captureObjectString(
          last.body.c_str(), last.body.length(), std::string(objectKey.c_str()),
          kMaxCapturedBytes, captured);
      if (result == CaptivePortalParsing::CaptureResult::TooLarge) {
        fail("CAPTURE_TOO_LARGE", "A captured portal value is too large."); return;
      }
      if (result != CaptivePortalParsing::CaptureResult::Found) {
        fail("CAPTURE_MISSING", "A required portal value could not be extracted."); return;
      }
      variables[std::string(name.c_str())] = String(captured.c_str());
      continue;
    }
    if (line.startsWith("CAPTURE_BETWEEN ")) {
      const String args = line.substring(16);
      const int nameEnd = args.indexOf(' ');
      const int delimiter = args.indexOf(" || ", nameEnd + 1);
      if (nameEnd <= 0 || delimiter < 0) { fail("INVALID_CAPTURE", "CAPTURE_BETWEEN requires name, prefix and suffix."); return; }
      bool beforeOK = false;
      bool afterOK = false;
      const String before = expand(args.substring(nameEnd + 1, delimiter), variables, beforeOK);
      const String after = expand(args.substring(delimiter + 4), variables, afterOK);
      const int start = last.body.indexOf(before);
      const int end = start < 0 ? -1 : last.body.indexOf(after, start + before.length());
      if (!beforeOK || !afterOK || start < 0 || end < 0) { fail("CAPTURE_MISSING", "A required portal value could not be extracted."); return; }
      if (static_cast<size_t>(end - start - before.length()) > kMaxCapturedBytes) {
        fail("CAPTURE_TOO_LARGE", "A captured portal value is too large."); return;
      }
      variables[std::string(args.substring(0, nameEnd).c_str())] = last.body.substring(start + before.length(), end);
      continue;
    }
    if (line.startsWith("IF_STATUS ")) {
      const String args = line.substring(10);
      const int marker = args.indexOf(" GOTO ");
      if (marker < 0) { fail("INVALID_CONDITION", "IF_STATUS requires GOTO."); return; }
      if (last.status == args.substring(0, marker).toInt() && !jump(args.substring(marker + 6))) return;
      continue;
    }
    if (line.startsWith("IF_BODY_CONTAINS ")) {
      const String args = line.substring(17);
      const int marker = args.lastIndexOf(" GOTO ");
      if (marker < 0) { fail("INVALID_CONDITION", "IF_BODY_CONTAINS requires GOTO."); return; }
      bool ok = false;
      const String expected = expand(args.substring(0, marker), variables, ok);
      if (!ok) { fail("MISSING_VARIABLE", "A condition references a missing variable."); return; }
      if (last.body.indexOf(expected) >= 0 && !jump(args.substring(marker + 6))) return;
      continue;
    }
    if (line.startsWith("IF_BODY_EQUALS ")) {
      const String args = line.substring(15);
      const int marker = args.lastIndexOf(" GOTO ");
      if (marker <= 0) { fail("INVALID_CONDITION", "IF_BODY_EQUALS requires text and GOTO."); return; }
      bool ok = false;
      const String expected = expand(args.substring(0, marker), variables, ok);
      if (!ok) { fail("MISSING_VARIABLE", "A condition references a missing variable."); return; }
      if (CaptivePortalParsing::bodyEqualsTrimmed(
              last.body.c_str(), last.body.length(), expected.c_str(), expected.length()) &&
          !jump(args.substring(marker + 6))) return;
      continue;
    }
    if (line.startsWith("IF_VAR_EQUALS ")) {
      const String args = line.substring(14);
      const int marker = args.lastIndexOf(" GOTO ");
      const int nameEnd = args.indexOf(' ');
      if (marker <= 0 || nameEnd <= 0 || nameEnd >= marker) {
        fail("INVALID_CONDITION", "IF_VAR_EQUALS requires a variable, value and GOTO."); return;
      }
      const String name = args.substring(0, nameEnd);
      if (!CaptivePortalParsing::isSimpleName(std::string(name.c_str()))) {
        fail("INVALID_CONDITION", "IF_VAR_EQUALS has an invalid variable name."); return;
      }
      bool ok = false;
      const String expected = expand(args.substring(nameEnd + 1, marker), variables, ok);
      if (!ok) { fail("MISSING_VARIABLE", "A condition references a missing variable."); return; }
      const auto found = variables.find(std::string(name.c_str()));
      const auto comparison = CaptivePortalParsing::compareVariable(
          found == variables.end() ? nullptr : found->second.c_str(), expected.c_str());
      if (comparison == CaptivePortalParsing::VariableComparison::Missing) {
        fail("MISSING_VARIABLE", "A condition references a missing variable."); return;
      }
      if (comparison == CaptivePortalParsing::VariableComparison::Equal &&
          !jump(args.substring(marker + 6))) return;
      continue;
    }
    if (line.startsWith("GOTO ")) { if (!jump(line.substring(5))) return; continue; }
    if (line == "SUCCESS" || line.startsWith("SUCCESS ")) {
      finishGate(record.ssid, CaptivePortalPolicy::GateState::Success);
      setStatus(State::Success, record.ssid,
                line.length() > 8 ? line.substring(8) : "Captive portal login succeeded.");
      LOG_WIFI("captive ssid=\"%s\" success", record.ssid.c_str());
      return;
    }
    if (line == "ALREADY_CONNECTED" || line.startsWith("ALREADY_CONNECTED ")) {
      finishGate(record.ssid, CaptivePortalPolicy::GateState::AlreadyConnected);
      setStatus(State::AlreadyConnected, record.ssid,
                line.length() > 18 ? line.substring(18) : "Internet was already available.");
      return;
    }
    if (line.startsWith("FAIL ")) {
      const String args = line.substring(5);
      const int separator = args.indexOf(' ');
      fail(separator < 0 ? args : args.substring(0, separator),
           separator < 0 ? "The script reported a failure." : args.substring(separator + 1));
      return;
    }
    fail("UNKNOWN_COMMAND", String("Unknown captive script command: ") + line);
    return;
  }
  fail(steps > kMaxSteps ? "STEP_LIMIT" : "NO_RESULT",
       steps > kMaxSteps ? "The script exceeded the 200-step safety limit."
                         : "The script ended without SUCCESS, ALREADY_CONNECTED or FAIL.");
}

void CaptivePortalAutomation::loop() {
  const bool connected = WiFi.status() == WL_CONNECTED && WiFi.getMode() != WIFI_AP;
  const String ssid = connected ? WiFi.SSID() : String();
  if (!connected) {
    observedSSID_ = "";
    pendingSSID_ = "";
    ranForCurrentConnection_ = false;
    disconnectGate();
    return;
  }
  if (ssid != observedSSID_) {
    observedSSID_ = ssid;
    pendingSSID_ = "";
    pendingSinceMs_ = millis();
    ranForCurrentConnection_ = false;
    const int index = find(ssid);
    ScriptRecord record;
    const bool enabledScript =
        index >= 0 && load(index, record) && record.enabled;
    associateGate(ssid, enabledScript);
    if (enabledScript) {
      pendingSSID_ = ssid;
      setStatus(State::Waiting, ssid, "Waiting for the Wi-Fi path to settle.");
    }
    return;
  }
  if (ranForCurrentConnection_ || pendingSSID_.isEmpty() || active()) return;
  ScriptRecord record;
  const int index = find(pendingSSID_);
  if (index < 0 || !load(index, record) || !record.enabled) {
    pendingSSID_ = "";
    associateGate(ssid, false);
    return;
  }
  if (millis() - pendingSinceMs_ < record.delayMs) return;
  ranForCurrentConnection_ = true;
  startForSSID(pendingSSID_, false);
}

bool CaptivePortalAutomation::handleCommand(const std::string &command, std::string &reply) {
  if (command.rfind("CAPTIVE ", 0) != 0) return false;
  if (command == "CAPTIVE STATUS") { reply = statusJson(); return true; }
  if (command == "CAPTIVE LIST") {
    reply = "{\"count\":" + std::to_string(count()) + "}";
    return true;
  }
  if (command.rfind("CAPTIVE GET ", 0) == 0) {
    unsigned long index = 0;
    ScriptRecord record;
    if (!parseUnsigned(command.substr(12), index) || !load(index, record)) reply = "error captive_not_found";
    else reply = std::string("{\"ssid\":\"") + jsonEscape(record.ssid).c_str() +
        "\",\"delay_ms\":" + std::to_string(record.delayMs) +
        ",\"enabled\":" + (record.enabled ? "true" : "false") +
        ",\"size\":" + std::to_string(record.script.length()) + "}";
    return true;
  }
  if (command.rfind("CAPTIVE READ ", 0) == 0) {
    const size_t first = command.find(' ', 13);
    const size_t second = first == std::string::npos ? first : command.find(' ', first + 1);
    unsigned long index = 0, offset = 0, length = 0;
    ScriptRecord record;
    if (first == std::string::npos || second == std::string::npos ||
        !parseUnsigned(command.substr(13, first - 13), index) ||
        !parseUnsigned(command.substr(first + 1, second - first - 1), offset) ||
        !parseUnsigned(command.substr(second + 1), length) || length == 0 || length > 60 ||
        !load(index, record) || offset > record.script.length()) {
      reply = "error captive_invalid";
    } else {
      const String part = record.script.substring(offset, std::min<size_t>(offset + length, record.script.length()));
      reply = std::string("captive data ") + std::to_string(offset) + " " + encodeHex(part).c_str();
    }
    return true;
  }
  if (command.rfind("CAPTIVE BEGIN ", 0) == 0) {
    std::vector<std::string> fields;
    size_t cursor = 14;
    while (cursor < command.size()) {
      const size_t next = command.find(' ', cursor);
      fields.push_back(command.substr(cursor, next == std::string::npos ? next : next - cursor));
      if (next == std::string::npos) break;
      cursor = next + 1;
    }
    uint64_t token = 0;
    String ssid;
    unsigned long delayMs = 0, size = 0, checksumValue = 0, enabled = 0;
    const bool valid = fields.size() == 6 && parseToken(fields[0], token) &&
        decodeHex(fields[1], ssid) && ssid.length() > 0 && ssid.length() <= 32 &&
        parseUnsigned(fields[2], delayMs) && delayMs <= MaxDelayMs &&
        parseUnsigned(fields[3], size) && size > 0 && size <= MaxScriptBytes &&
        parseUnsigned(fields[4], checksumValue, 16) && parseUnsigned(fields[5], enabled) && enabled <= 1;
    if (!valid) reply = "error captive_invalid";
    else beginUpload(token, ssid, delayMs, size, static_cast<uint32_t>(checksumValue),
                     enabled == 1, reply);
    return true;
  }
  if (command.rfind("CAPTIVE DATA ", 0) == 0) {
    const size_t first = command.find(' ', 13);
    const size_t second = first == std::string::npos ? first : command.find(' ', first + 1);
    uint64_t token = 0;
    unsigned long offset = 0;
    const std::string encoded = second == std::string::npos ? "" : command.substr(second + 1);
    bool valid = first != std::string::npos && second != std::string::npos &&
        parseToken(command.substr(13, first - 13), token) &&
        parseUnsigned(command.substr(first + 1, second - first - 1), offset) &&
        !encoded.empty() && !(encoded.size() & 1);
    std::vector<uint8_t> decoded;
    if (valid) {
      decoded.reserve(encoded.size() / 2);
      for (size_t i = 0; i < encoded.size(); i += 2) {
        const int high = nibble(encoded[i]), low = nibble(encoded[i + 1]);
        if (high < 0 || low < 0) { valid = false; break; }
        decoded.push_back(static_cast<uint8_t>((high << 4) | low));
      }
    }
    if (!valid) reply = "error captive_invalid";
    else writeUpload(token, offset, decoded.data(), decoded.size(), reply);
    return true;
  }
  if (command.rfind("CAPTIVE COMMIT ", 0) == 0) {
    uint64_t token = 0;
    const bool valid = CaptivePortalParsing::parseCommitToken(command, token) && upload_.active &&
        token == upload_.token && upload_.bytes.size() == upload_.expectedSize &&
        checksum(upload_.bytes.data(), upload_.bytes.size()) == upload_.expectedChecksum;
    if (!valid) reply = "error captive_checksum";
    else {
      ScriptRecord record;
      record.ssid = upload_.ssid; record.delayMs = upload_.delayMs;
      record.enabled = upload_.enabled;
      record.script = String(reinterpret_cast<const char *>(upload_.bytes.data()), upload_.bytes.size());
      reply = save(record) ? "captive committed" : "error captive_storage";
      if (reply == "captive committed" && WiFi.status() == WL_CONNECTED && WiFi.SSID() == record.ssid) {
        observedSSID_ = "";  // Arm the newly saved workflow for the current association.
      }
      upload_ = Upload();
    }
    return true;
  }
  if (command.rfind("CAPTIVE REMOVE ", 0) == 0) {
    String ssid;
    reply = decodeHex(command.substr(15), ssid) && remove(ssid)
        ? "captive removed" : "error captive_not_found";
    if (reply == "captive removed" && WiFi.status() == WL_CONNECTED &&
        WiFi.SSID() == ssid) {
      observedSSID_ = "";  // Re-evaluate the gate for the current association.
    }
    return true;
  }
  if (command.rfind("CAPTIVE RUN ", 0) == 0) {
    String ssid;
    if (!decodeHex(command.substr(12), ssid) || WiFi.status() != WL_CONNECTED || WiFi.SSID() != ssid)
      reply = "error captive_wrong_network";
    else reply = startForSSID(ssid, true) ? "captive started" : "error captive_busy";
    return true;
  }
  if (command == "CAPTIVE ABORT" || command.rfind("CAPTIVE ABORT ", 0) == 0) {
    uint64_t token = 0;
    const bool tokenValid = command == "CAPTIVE ABORT" ||
        parseToken(command.substr(14), token);
    if (!tokenValid || (token != 0 && upload_.active && token != upload_.token)) {
      reply = "error captive_wrong_token";
    } else {
      upload_ = Upload();
      reply = "captive aborted";
    }
    return true;
  }
  reply = "error captive_invalid";
  return true;
}

void CaptivePortalAutomation::beginUpload(uint64_t token, const String &ssid,
                                           uint32_t delayMs, size_t size,
                                           uint32_t checksumValue, bool enabled,
                                           std::string &reply) {
  if (token == 0 || ssid.isEmpty() || ssid.length() > 32 || delayMs > MaxDelayMs ||
      size == 0 || size > MaxScriptBytes || (find(ssid) < 0 && count() >= MaxScripts)) {
    reply = "error captive_invalid";
    return;
  }
  if (upload_.active) {
    if (upload_.token != token) { reply = "error captive_busy"; return; }
    if (upload_.ssid != ssid || upload_.delayMs != delayMs ||
        upload_.expectedSize != size || upload_.expectedChecksum != checksumValue ||
        upload_.enabled != enabled) {
      reply = "error captive_invalid";
      return;
    }
  } else {
    upload_.active = true;
    upload_.token = token;
    upload_.ssid = ssid;
    upload_.delayMs = delayMs;
    upload_.expectedSize = size;
    upload_.expectedChecksum = checksumValue;
    upload_.enabled = enabled;
    upload_.bytes.clear();
    upload_.bytes.reserve(size);
  }
  char tokenText[17];
  snprintf(tokenText, sizeof(tokenText), "%016llx", static_cast<unsigned long long>(token));
  reply = std::string("captive ready ") + tokenText + " " +
          std::to_string(upload_.bytes.size());
}

void CaptivePortalAutomation::writeUpload(uint64_t token, uint32_t offset,
                                           const uint8_t *data, size_t length,
                                           std::string &reply) {
  if (!upload_.active || token != upload_.token || offset != upload_.bytes.size() ||
      !data || length == 0 || upload_.bytes.size() + length > upload_.expectedSize) {
    reply = "error captive_invalid";
    return;
  }
  upload_.bytes.insert(upload_.bytes.end(), data, data + length);
  char tokenText[17];
  snprintf(tokenText, sizeof(tokenText), "%016llx", static_cast<unsigned long long>(token));
  reply = std::string("captive ack ") + tokenText + " " +
          std::to_string(upload_.bytes.size());
}

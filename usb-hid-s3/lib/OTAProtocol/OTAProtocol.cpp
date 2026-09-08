#include "OTAProtocol.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <sstream>
#include <vector>

namespace {

struct ParsedVersion {
  std::vector<uint32_t> components;
  std::vector<std::string> prerelease;
};

bool parseVersion(const std::string &value, ParsedVersion &out) {
  const size_t build = value.find('+');
  const std::string withoutBuild = value.substr(0, build);
  const size_t dash = withoutBuild.find('-');
  const std::string core = withoutBuild.substr(0, dash);
  std::istringstream components(core);
  std::string item;
  while (std::getline(components, item, '.')) {
    if (item.empty()) return false;
    char *end = nullptr;
    const unsigned long parsed = std::strtoul(item.c_str(), &end, 10);
    if (!end || *end || parsed > UINT32_MAX) return false;
    out.components.push_back(static_cast<uint32_t>(parsed));
  }
  if (out.components.empty()) return false;
  if (dash == std::string::npos) return true;
  std::istringstream identifiers(withoutBuild.substr(dash + 1));
  while (std::getline(identifiers, item, '.')) {
    if (item.empty()) return false;
    for (char c : item) {
      if (!std::isalnum(static_cast<unsigned char>(c)) && c != '-') return false;
    }
    out.prerelease.push_back(item);
  }
  return !out.prerelease.empty();
}

bool numericIdentifier(const std::string &value, uint32_t &out) {
  if (value.empty()) return false;
  for (char c : value) if (!std::isdigit(static_cast<unsigned char>(c))) return false;
  char *end = nullptr;
  const unsigned long parsed = std::strtoul(value.c_str(), &end, 10);
  if (!end || *end || parsed > UINT32_MAX) return false;
  out = static_cast<uint32_t>(parsed);
  return true;
}

int compareVersions(const ParsedVersion &left, const ParsedVersion &right) {
  const size_t componentCount = std::max(left.components.size(), right.components.size());
  for (size_t index = 0; index < componentCount; ++index) {
    const uint32_t lhs = index < left.components.size() ? left.components[index] : 0;
    const uint32_t rhs = index < right.components.size() ? right.components[index] : 0;
    if (lhs != rhs) return lhs < rhs ? -1 : 1;
  }
  if (left.prerelease.empty() != right.prerelease.empty())
    return left.prerelease.empty() ? 1 : -1;
  const size_t identifierCount = std::max(left.prerelease.size(), right.prerelease.size());
  for (size_t index = 0; index < identifierCount; ++index) {
    if (index >= left.prerelease.size()) return -1;
    if (index >= right.prerelease.size()) return 1;
    const std::string &lhs = left.prerelease[index];
    const std::string &rhs = right.prerelease[index];
    if (lhs == rhs) continue;
    uint32_t lhsNumber = 0, rhsNumber = 0;
    const bool lhsNumeric = numericIdentifier(lhs, lhsNumber);
    const bool rhsNumeric = numericIdentifier(rhs, rhsNumber);
    if (lhsNumeric && rhsNumeric) return lhsNumber < rhsNumber ? -1 : 1;
    if (lhsNumeric != rhsNumeric) return lhsNumeric ? -1 : 1;
    return lhs < rhs ? -1 : 1;
  }
  return 0;
}

}  // namespace

bool OTAProtocol::validSha256(const std::string &value) {
  if (value.size() != 64) return false;
  for (char c : value) if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
  return true;
}

bool OTAProtocol::isDowngrade(const std::string &current,
                              const std::string &target) {
  ParsedVersion currentVersion, targetVersion;
  if (!parseVersion(current, currentVersion) || !parseVersion(target, targetVersion))
    return false;
  return compareVersions(targetVersion, currentVersion) < 0;
}

bool OTAProtocol::parseStart(const std::string &line, OTAStartRequest &out,
                             std::string &error) {
  out = OTAStartRequest{};
  error.clear();
  std::istringstream input(line);
  std::string command;
  input >> command;
  if (command != "START") { error = "invalid_command"; return false; }
  bool haveProtocol = false, haveSize = false, haveVersion = false, haveHash = false;
  std::string field;
  while (input >> field) {
    const size_t separator = field.find('=');
    if (separator == std::string::npos) { error = "invalid_metadata"; return false; }
    const std::string key = field.substr(0, separator);
    const std::string value = field.substr(separator + 1);
    char *end = nullptr;
    if (key == "protocol") {
      unsigned long parsed = std::strtoul(value.c_str(), &end, 10);
      if (!end || *end || parsed > UINT32_MAX) { error = "invalid_protocol"; return false; }
      out.protocol = static_cast<uint32_t>(parsed); haveProtocol = true;
    } else if (key == "size") {
      unsigned long parsed = std::strtoul(value.c_str(), &end, 10);
      if (!end || *end || parsed == 0 || parsed > UINT32_MAX) { error = "invalid_size"; return false; }
      out.size = static_cast<uint32_t>(parsed); haveSize = true;
    } else if (key == "version") { out.version = value; haveVersion = !value.empty(); }
    else if (key == "sha256") { out.sha256 = value; haveHash = validSha256(value); }
    else if (key == "flow") { out.windowed = value == "windowed"; }
    else if (key == "binary") { out.binary = value == "1"; }
    else if (key == "allow_downgrade") { out.allowDowngrade = value == "1"; }
  }
  if (!haveProtocol) error = "missing_protocol";
  else if (!haveSize) error = "missing_size";
  else if (!haveVersion) error = "missing_version";
  else if (!haveHash) error = "invalid_sha256";
  else return true;
  return false;
}

bool OTAProtocol::acceptsOffset(uint32_t expected, uint32_t offset,
                                size_t payload, uint32_t total) {
  return offset == expected && payload > 0 && payload <= total - expected;
}

bool OTAProtocol::shouldAcknowledge(uint32_t received, uint32_t lastAck,
                                    uint32_t total, bool windowed,
                                    uint32_t acknowledgementWindow) {
  if (!windowed) return true;
  return received == total ||
         (received >= lastAck && received - lastAck >= acknowledgementWindow);
}

const char *OTAProtocol::stateName(OTAState state) {
  switch (state) {
    case OTAState::Idle: return "idle"; case OTAState::Preparing: return "preparing";
    case OTAState::Receiving: return "receiving"; case OTAState::Verifying: return "verifying";
    case OTAState::Installing: return "installing"; case OTAState::Rebooting: return "rebooting";
    case OTAState::Complete: return "complete"; case OTAState::Failed: return "failed";
    case OTAState::Cancelled: return "cancelled";
  }
  return "failed";
}

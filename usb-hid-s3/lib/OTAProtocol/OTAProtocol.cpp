#include "OTAProtocol.h"

#include <cctype>
#include <cstdlib>
#include <sstream>

bool OTAProtocol::validSha256(const std::string &value) {
  if (value.size() != 64) return false;
  for (char c : value) if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
  return true;
}

bool OTAProtocol::parseStart(const std::string &line, OTAStartRequest &out,
                             std::string &error) {
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

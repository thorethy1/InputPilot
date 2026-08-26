#ifndef OTA_PROTOCOL_H
#define OTA_PROTOCOL_H

#include <cstddef>
#include <cstdint>
#include <string>

enum class OTAState { Idle, Preparing, Receiving, Verifying, Installing, Rebooting, Complete, Failed, Cancelled };

struct OTAStartRequest {
  uint32_t protocol = 0;
  uint32_t size = 0;
  std::string version;
  std::string sha256;
};

class OTAProtocol {
 public:
  static bool parseStart(const std::string &line, OTAStartRequest &request,
                         std::string &error);
  static bool validSha256(const std::string &value);
  static bool acceptsOffset(uint32_t expected, uint32_t offset, size_t payload,
                            uint32_t total);
  static const char *stateName(OTAState state);
};

#endif

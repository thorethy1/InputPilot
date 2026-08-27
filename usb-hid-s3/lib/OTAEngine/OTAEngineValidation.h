#ifndef OTA_ENGINE_VALIDATION_H
#define OTA_ENGINE_VALIDATION_H
#include <string>
#include "Config.h"
#include "FirmwareMetadata.h"
#include "OTAProtocol.h"
class OTAEngineValidation {
 public:
  static bool start(bool active, const OTAStartRequest &request, uint32_t maximum, std::string &error) {
    if (active) error = "update_in_progress";
    else if (request.protocol != OTA_PROTOCOL_VERSION) error = "unsupported_protocol";
    else if (!request.size) error = "invalid_size";
    else if (request.size > maximum) error = "firmware_too_large";
    else if (request.version.empty() || !OTAProtocol::validSha256(request.sha256)) error = "invalid_metadata";
    else return true;
    return false;
  }
  static bool write(uint32_t received, uint32_t offset, size_t size, uint32_t total, std::string &error) {
    if (OTAProtocol::acceptsOffset(received, offset, size, total)) return true;
    error = "invalid_offset"; return false;
  }
  static bool completion(uint32_t received, const OTAStartRequest &request,
                         const std::string &calculatedSha, const FirmwareMetadataValue &metadata,
                         std::string &error) {
    if (received != request.size) error = "incomplete_firmware";
    else if (calculatedSha != request.sha256) error = "checksum_mismatch";
    else if (!FirmwareMetadata::compatible(metadata, error)) return false;
    else if (metadata.version != request.version) error = "version_mismatch";
    else return true;
    return false;
  }
};
#endif

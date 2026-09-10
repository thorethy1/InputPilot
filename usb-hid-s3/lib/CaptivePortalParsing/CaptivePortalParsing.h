#ifndef INPUTPILOT_CAPTIVE_PORTAL_PARSING_H
#define INPUTPILOT_CAPTIVE_PORTAL_PARSING_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace CaptivePortalParsing {

enum class CaptureResult {
  Found,
  Missing,
  TooLarge,
  Malformed,
};

enum class VariableComparison {
  Equal,
  NotEqual,
  Missing,
};

bool isSimpleName(const std::string &value);
bool isDotPath(const std::string &value);

// Parses the token from the complete CAPTIVE COMMIT command. Keeping the
// prefix handling next to the parser avoids offset drift between commands.
bool parseCommitToken(const std::string &command, uint64_t &token);

CaptureResult captureObjectString(const char *body, size_t bodyLength,
                                  const std::string &key, size_t maximumBytes,
                                  std::string &value);

CaptureResult captureJsonScalar(const char *body, size_t bodyLength,
                                const std::string &path, size_t maximumBytes,
                                std::string &value);

CaptureResult captureFirstJsonScalar(const char *body, size_t bodyLength,
                                     const std::vector<std::string> &paths,
                                     size_t maximumBytes, std::string &value);

bool bodyEqualsTrimmed(const char *body, size_t bodyLength,
                       const char *expected, size_t expectedLength);

VariableComparison compareVariable(const char *actual, const char *expected);

}  // namespace CaptivePortalParsing

#endif  // INPUTPILOT_CAPTIVE_PORTAL_PARSING_H

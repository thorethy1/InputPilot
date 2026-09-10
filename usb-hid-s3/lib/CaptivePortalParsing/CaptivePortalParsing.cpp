#include "CaptivePortalParsing.h"

#include <ArduinoJson.h>

#include <cctype>
#include <cstdio>
#include <cstring>

namespace CaptivePortalParsing {
namespace {

bool isJsonWhitespace(char value) {
  return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

constexpr char kCommitPrefix[] = "CAPTIVE COMMIT ";

int hexDigit(char value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

bool parseHexCodeUnit(const char *body, size_t bodyLength, size_t &cursor,
                      uint16_t &value) {
  if (cursor + 4 > bodyLength) return false;
  value = 0;
  for (size_t index = 0; index < 4; ++index) {
    const int digit = hexDigit(body[cursor++]);
    if (digit < 0) return false;
    value = static_cast<uint16_t>((value << 4) | digit);
  }
  return true;
}

bool appendUtf8(uint32_t codePoint, size_t maximumBytes, std::string &value) {
  if (codePoint == 0) return false;
  char encoded[4];
  size_t count = 0;
  if (codePoint <= 0x7f) {
    encoded[count++] = static_cast<char>(codePoint);
  } else if (codePoint <= 0x7ff) {
    encoded[count++] = static_cast<char>(0xc0 | (codePoint >> 6));
    encoded[count++] = static_cast<char>(0x80 | (codePoint & 0x3f));
  } else if (codePoint <= 0xffff) {
    encoded[count++] = static_cast<char>(0xe0 | (codePoint >> 12));
    encoded[count++] = static_cast<char>(0x80 | ((codePoint >> 6) & 0x3f));
    encoded[count++] = static_cast<char>(0x80 | (codePoint & 0x3f));
  } else if (codePoint <= 0x10ffff) {
    encoded[count++] = static_cast<char>(0xf0 | (codePoint >> 18));
    encoded[count++] = static_cast<char>(0x80 | ((codePoint >> 12) & 0x3f));
    encoded[count++] = static_cast<char>(0x80 | ((codePoint >> 6) & 0x3f));
    encoded[count++] = static_cast<char>(0x80 | (codePoint & 0x3f));
  } else {
    return false;
  }
  if (value.size() + count > maximumBytes) return false;
  value.append(encoded, count);
  return true;
}

CaptureResult parseQuotedString(const char *body, size_t bodyLength,
                                size_t cursor, size_t maximumBytes,
                                std::string &value) {
  value.clear();
  while (cursor < bodyLength) {
    const unsigned char character = static_cast<unsigned char>(body[cursor++]);
    if (character == '"') return CaptureResult::Found;
    if (character < 0x20) return CaptureResult::Malformed;
    if (character != '\\') {
      if (value.size() >= maximumBytes) return CaptureResult::TooLarge;
      value.push_back(static_cast<char>(character));
      continue;
    }
    if (cursor >= bodyLength) return CaptureResult::Malformed;
    const char escaped = body[cursor++];
    char decoded = 0;
    switch (escaped) {
      case '"': decoded = '"'; break;
      case '\\': decoded = '\\'; break;
      case '/': decoded = '/'; break;
      case 'b': decoded = '\b'; break;
      case 'f': decoded = '\f'; break;
      case 'n': decoded = '\n'; break;
      case 'r': decoded = '\r'; break;
      case 't': decoded = '\t'; break;
      case 'u': {
        uint16_t first = 0;
        if (!parseHexCodeUnit(body, bodyLength, cursor, first))
          return CaptureResult::Malformed;
        uint32_t codePoint = first;
        if (first >= 0xd800 && first <= 0xdbff) {
          if (cursor + 2 > bodyLength || body[cursor] != '\\' ||
              body[cursor + 1] != 'u')
            return CaptureResult::Malformed;
          cursor += 2;
          uint16_t second = 0;
          if (!parseHexCodeUnit(body, bodyLength, cursor, second) ||
              second < 0xdc00 || second > 0xdfff)
            return CaptureResult::Malformed;
          codePoint = 0x10000u +
              ((static_cast<uint32_t>(first) - 0xd800u) << 10) +
              (static_cast<uint32_t>(second) - 0xdc00u);
        } else if (first >= 0xdc00 && first <= 0xdfff) {
          return CaptureResult::Malformed;
        }
        if (codePoint == 0) return CaptureResult::Malformed;
        if (!appendUtf8(codePoint, maximumBytes, value))
          return codePoint <= 0x10ffff ? CaptureResult::TooLarge
                                      : CaptureResult::Malformed;
        continue;
      }
      default: return CaptureResult::Malformed;
    }
    if (value.size() >= maximumBytes) return CaptureResult::TooLarge;
    value.push_back(decoded);
  }
  return CaptureResult::Malformed;
}

JsonVariantConst variantAtPath(JsonVariantConst root, const std::string &path) {
  size_t cursor = 0;
  JsonVariantConst variant = root;
  while (cursor < path.size()) {
    const size_t separator = path.find('.', cursor);
    const std::string component = path.substr(
        cursor, separator == std::string::npos ? std::string::npos
                                               : separator - cursor);
    if (!variant.is<JsonObjectConst>()) return JsonVariantConst();
    variant = variant[component.c_str()];
    if (variant.isNull()) return JsonVariantConst();
    if (separator == std::string::npos) return variant;
    cursor = separator + 1;
  }
  return JsonVariantConst();
}

bool scalarString(JsonVariantConst variant, std::string &value) {
  if (variant.is<const char *>()) {
    const char *text = variant.as<const char *>();
    value = text ? text : "";
    return true;
  }
  if (variant.is<bool>()) {
    value = variant.as<bool>() ? "true" : "false";
    return true;
  }
  if (variant.is<long>()) {
    value = std::to_string(variant.as<long>());
    return true;
  }
  if (variant.is<double>()) {
    char buffer[48];
    std::snprintf(buffer, sizeof(buffer), "%.8f", variant.as<double>());
    value = buffer;
    return true;
  }
  return false;
}

}  // namespace

bool parseCommitToken(const std::string &command, uint64_t &token) {
  constexpr size_t prefixLength = sizeof(kCommitPrefix) - 1;
  if (command.compare(0, prefixLength, kCommitPrefix) != 0) return false;
  const std::string text = command.substr(prefixLength);
  if (text.empty() || text.size() > 16) return false;
  uint64_t value = 0;
  for (const char character : text) {
    const int digit = hexDigit(character);
    if (digit < 0) return false;
    value = (value << 4) | static_cast<uint64_t>(digit);
  }
  if (value == 0) return false;
  token = value;
  return true;
}

bool isSimpleName(const std::string &value) {
  if (value.empty()) return false;
  for (const unsigned char character : value) {
    if (!std::isalnum(character) && character != '_' && character != '-')
      return false;
  }
  return true;
}

bool isDotPath(const std::string &value) {
  if (value.empty()) return false;
  size_t cursor = 0;
  while (cursor < value.size()) {
    const size_t separator = value.find('.', cursor);
    const std::string component = value.substr(
        cursor, separator == std::string::npos ? std::string::npos
                                               : separator - cursor);
    if (!isSimpleName(component)) return false;
    if (separator == std::string::npos) return true;
    cursor = separator + 1;
  }
  return false;
}

CaptureResult captureObjectString(const char *body, size_t bodyLength,
                                  const std::string &key, size_t maximumBytes,
                                  std::string &value) {
  value.clear();
  if (!body || !isSimpleName(key)) return CaptureResult::Malformed;
  const std::string needle = "\"" + key + "\"";
  bool malformedCandidate = false;
  for (size_t start = 0; start + needle.size() <= bodyLength; ++start) {
    if (std::memcmp(body + start, needle.data(), needle.size()) != 0) continue;
    size_t cursor = start + needle.size();
    while (cursor < bodyLength && isJsonWhitespace(body[cursor])) ++cursor;
    if (cursor >= bodyLength || body[cursor] != ':') {
      malformedCandidate = true;
      continue;
    }
    ++cursor;
    while (cursor < bodyLength && isJsonWhitespace(body[cursor])) ++cursor;
    if (cursor >= bodyLength || body[cursor] != '"') {
      malformedCandidate = true;
      continue;
    }
    const CaptureResult result = parseQuotedString(
        body, bodyLength, cursor + 1, maximumBytes, value);
    if (result == CaptureResult::Found || result == CaptureResult::TooLarge)
      return result;
    malformedCandidate = true;
  }
  return malformedCandidate ? CaptureResult::Malformed : CaptureResult::Missing;
}

CaptureResult captureFirstJsonScalar(const char *body, size_t bodyLength,
                                     const std::vector<std::string> &paths,
                                     size_t maximumBytes, std::string &value) {
  value.clear();
  if (!body || paths.empty()) return CaptureResult::Malformed;
  JsonDocument document;
  if (deserializeJson(document, body, bodyLength) != DeserializationError::Ok)
    return CaptureResult::Malformed;
  const JsonVariantConst root = document.as<JsonVariantConst>();
  for (const std::string &path : paths) {
    if (!isDotPath(path)) return CaptureResult::Malformed;
    const JsonVariantConst variant = variantAtPath(root, path);
    std::string candidate;
    if (variant.isNull() || !scalarString(variant, candidate) || candidate.empty())
      continue;
    if (candidate.size() > maximumBytes) return CaptureResult::TooLarge;
    value = candidate;
    return CaptureResult::Found;
  }
  return CaptureResult::Missing;
}

CaptureResult captureJsonScalar(const char *body, size_t bodyLength,
                                const std::string &path, size_t maximumBytes,
                                std::string &value) {
  value.clear();
  if (!body || path.empty()) return CaptureResult::Malformed;
  JsonDocument document;
  if (deserializeJson(document, body, bodyLength) != DeserializationError::Ok)
    return CaptureResult::Malformed;
  const JsonVariantConst variant = variantAtPath(
      document.as<JsonVariantConst>(), path);
  if (variant.isNull() || !scalarString(variant, value))
    return CaptureResult::Missing;
  if (value.size() > maximumBytes) return CaptureResult::TooLarge;
  return CaptureResult::Found;
}

bool bodyEqualsTrimmed(const char *body, size_t bodyLength,
                       const char *expected, size_t expectedLength) {
  if (!body || !expected) return false;
  size_t start = 0;
  while (start < bodyLength &&
         std::isspace(static_cast<unsigned char>(body[start]))) ++start;
  size_t end = bodyLength;
  while (end > start &&
         std::isspace(static_cast<unsigned char>(body[end - 1]))) --end;
  return end - start == expectedLength &&
         std::memcmp(body + start, expected, expectedLength) == 0;
}

VariableComparison compareVariable(const char *actual, const char *expected) {
  if (!actual) return VariableComparison::Missing;
  if (!expected) return VariableComparison::NotEqual;
  return std::strcmp(actual, expected) == 0 ? VariableComparison::Equal
                                           : VariableComparison::NotEqual;
}

}  // namespace CaptivePortalParsing

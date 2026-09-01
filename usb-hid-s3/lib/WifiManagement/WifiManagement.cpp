#include "WifiManagement.h"

namespace WifiManagement {
namespace {

bool validSsid(const std::string &ssid) {
  return !ssid.empty() && ssid.size() <= 32 &&
         ssid.find('\0') == std::string::npos;
}

bool validPassword(const std::string &password) {
  return password.size() <= 63 &&
         password.find('\0') == std::string::npos;
}

}  // namespace

Result invalid(Operation operation) {
  return {operation, Error::InvalidCredentials, {}};
}

Result set(Backend &backend, const std::string &ssid,
           const std::string &password) {
  if (!validSsid(ssid) || !validPassword(password))
    return invalid(Operation::Set);
  if (!backend.save(ssid, password))
    return {Operation::Set, Error::StorageFailed, {}};
  return {Operation::Set, Error::None, ssid};
}

Result remove(Backend &backend, const std::string &ssid) {
  if (!validSsid(ssid)) return invalid(Operation::Remove);
  if (!backend.remove(ssid))
    return {Operation::Remove, Error::NetworkNotFound, {}};
  return {Operation::Remove, Error::None, {}};
}

Result clear(Backend &backend) {
  if (!backend.clear())
    return {Operation::Clear, Error::StorageFailed, {}};
  return {Operation::Clear, Error::None, {}};
}

void apply(Backend &backend, const Result &result) {
  if (result.accepted()) backend.apply(result.provisionedSsid);
}

const char *acceptedReply(Operation operation) {
  switch (operation) {
    case Operation::Set:
      return "{\"operation\":\"wifi_set\",\"status\":\"accepted\"}";
    case Operation::Remove:
      return "{\"operation\":\"wifi_remove\",\"status\":\"accepted\"}";
    case Operation::Clear:
      return "{\"operation\":\"wifi_clear\",\"status\":\"accepted\"}";
  }
  return "error unsupported_management_operation";
}

const char *errorReply(Error error) {
  switch (error) {
    case Error::InvalidCredentials:
      return "error invalid_wifi_credentials";
    case Error::StorageFailed:
      return "error wifi_storage_failed";
    case Error::NetworkNotFound:
      return "error wifi_network_not_found";
    case Error::None:
      break;
  }
  return "error unsupported_management_operation";
}

}  // namespace WifiManagement

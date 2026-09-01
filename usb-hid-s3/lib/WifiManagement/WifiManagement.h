#ifndef INPUTPILOT_WIFI_MANAGEMENT_H
#define INPUTPILOT_WIFI_MANAGEMENT_H

#include <string>

namespace WifiManagement {

enum class Operation {
  Set,
  Remove,
  Clear,
};

enum class Error {
  None,
  InvalidCredentials,
  StorageFailed,
  NetworkNotFound,
};

struct Result {
  Operation operation;
  Error error = Error::None;
  std::string provisionedSsid;

  bool accepted() const { return error == Error::None; }
};

class Backend {
 public:
  virtual ~Backend() = default;

  virtual bool save(const std::string &ssid, const std::string &password) = 0;
  virtual bool remove(const std::string &ssid) = 0;
  virtual bool clear() = 0;
  virtual void apply(const std::string &provisionedSsid) = 0;
};

Result invalid(Operation operation);
Result set(Backend &backend, const std::string &ssid,
           const std::string &password);
Result remove(Backend &backend, const std::string &ssid);
Result clear(Backend &backend);

// Apply is deliberately separate from persistence so the protocol layer can
// acknowledge an accepted request before changing Wi-Fi radio state.
void apply(Backend &backend, const Result &result);

const char *acceptedReply(Operation operation);
const char *errorReply(Error error);

}  // namespace WifiManagement

#endif  // INPUTPILOT_WIFI_MANAGEMENT_H

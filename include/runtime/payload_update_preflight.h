#ifndef SIGHTER_RUNTIME_PAYLOAD_UPDATE_PREFLIGHT_H_
#define SIGHTER_RUNTIME_PAYLOAD_UPDATE_PREFLIGHT_H_

#include <string>

#include "runtime/environment.h"
#include "runtime/runtime_paths.h"

namespace sighter {
namespace runtime {

struct PayloadUpdatePreflightResult {
  bool attempted = false;
  std::string error;
  // Last failure the updater reported on its own stderr. Empty when the
  // updater never ran or never explained itself.
  std::string details;

  explicit operator bool() const { return error.empty(); }
};

PayloadUpdatePreflightResult RunPayloadUpdatePreflight(
    const Environment& environment, const RuntimePaths& paths,
    bool force_run_latest = false);

}  // namespace runtime
}  // namespace sighter

#endif  // SIGHTER_RUNTIME_PAYLOAD_UPDATE_PREFLIGHT_H_

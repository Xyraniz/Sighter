#ifndef SIGHTER_COMPAT_PAYLOAD_COMPATIBILITY_H_
#define SIGHTER_COMPAT_PAYLOAD_COMPATIBILITY_H_

#include <string>

#include "compat/build_profile.h"

namespace sighter {
namespace compat {

// Result of the side-effect-free compatibility gate used before any network,
// authentication, or native-loader work. The legacy runtime repeats the
// profile application while that ownership is migrated, but external startup
// services must not run until this gate succeeds.
struct PayloadCompatibilityResult {
  BuildProfile profile;
  std::string build_id;
  std::string error;

  explicit operator bool() const noexcept { return error.empty(); }
};

PayloadCompatibilityResult CheckPayloadCompatibility(
    const std::string& library_path, const std::string& manifest_path,
    bool allow_unverified_build);

}  // namespace compat
}  // namespace sighter

#endif  // SIGHTER_COMPAT_PAYLOAD_COMPATIBILITY_H_

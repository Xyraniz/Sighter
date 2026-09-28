#ifndef SIGHTER_UPDATE_UNSAFE_LATEST_RUNNER_H_
#define SIGHTER_UPDATE_UNSAFE_LATEST_RUNNER_H_

#include <filesystem>
#include <string>
#include <vector>

namespace sighter::update {

// Launches a downloaded latest payload once without promoting it to the active
// store. A non-empty HostAbi profile puts the child in explicit candidate mode;
// normal startup approval is intentionally not created or modified.
struct UnsafeLatestRunOptions {
  std::filesystem::path runtime_binary;
  std::filesystem::path payload_directory;
  std::filesystem::path compatibility_manifest;
  std::filesystem::path host_abi_profile;

  // Tests may supply a deterministic environment. Production callers leave
  // this empty to inherit the updater process environment.
  std::vector<std::string> inherited_environment;
};

struct UnsafeLatestRunResult {
  int exit_code = -1;
  std::string error;

  explicit operator bool() const { return error.empty() && exit_code == 0; }
};

UnsafeLatestRunResult RunUnsafeLatestCandidate(
    const UnsafeLatestRunOptions& options);

}  // namespace sighter::update

#endif  // SIGHTER_UPDATE_UNSAFE_LATEST_RUNNER_H_

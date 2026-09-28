#include "update/unsafe_latest_runner.h"

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

extern char** environ;

namespace sighter::update {
namespace {

constexpr std::array<std::string_view, 10> kOverriddenVariables = {
    "ROBLOX_LIB_PATH",
    "SIGHTER_ASSET_ROOT",
    "SIGHTER_ASSET_PATH",
    "SIGHTER_COMPATIBILITY_MANIFEST",
    "SIGHTER_HOST_ABI_PROFILE_FILE",
    "SIGHTER_HOST_ABI_CANARY",
    "SIGHTER_ALLOW_CANDIDATE_HOST_ABI",
    "SIGHTER_HOST_ABI_APPROVAL_RECEIPT",
    "SIGHTER_SKIP_UPDATE_CHECK",
    "SIGHTER_UNSAFE_LATEST",
};

bool IsEnvironmentEntry(std::string_view entry, std::string_view name) {
  return entry.size() > name.size() && entry[name.size()] == '=' &&
         entry.substr(0, name.size()) == name;
}

bool IsOverridden(std::string_view entry) {
  for (const std::string_view name : kOverriddenVariables) {
    if (IsEnvironmentEntry(entry, name)) return true;
  }
  return false;
}

bool IsRegularFile(const std::filesystem::path& path) {
  std::error_code error;
  const std::filesystem::file_status status =
      std::filesystem::symlink_status(path, error);
  return !error && std::filesystem::is_regular_file(status) &&
         !std::filesystem::is_symlink(status);
}

bool IsExecutableRegularFile(const std::filesystem::path& path) {
  return IsRegularFile(path) && access(path.c_str(), X_OK) == 0;
}

std::vector<std::string> CurrentEnvironment() {
  std::vector<std::string> result;
  for (char** entry = environ; entry != nullptr && *entry != nullptr; ++entry) {
    result.emplace_back(*entry);
  }
  return result;
}

std::vector<std::string> BuildEnvironment(
    const UnsafeLatestRunOptions& options) {
  const std::vector<std::string> inherited =
      options.inherited_environment.empty() ? CurrentEnvironment()
                                            : options.inherited_environment;
  std::vector<std::string> result;
  result.reserve(inherited.size() + 10U);
  for (const std::string& entry : inherited) {
    if (entry.find('\0') == std::string::npos && !IsOverridden(entry)) {
      result.push_back(entry);
    }
  }
  const auto add = [&](std::string_view name,
                       const std::filesystem::path& value) {
    result.push_back(std::string(name) + "=" + value.string());
  };
  add("ROBLOX_LIB_PATH", options.payload_directory / "libroblox.so");
  add("SIGHTER_ASSET_ROOT", options.payload_directory / "assets");
  add("SIGHTER_ASSET_PATH", options.payload_directory / "assets/content");
  add("SIGHTER_COMPATIBILITY_MANIFEST", options.compatibility_manifest);
  result.push_back("SIGHTER_SKIP_UPDATE_CHECK=1");
  result.push_back("SIGHTER_UNSAFE_LATEST=1");
  if (!options.host_abi_profile.empty()) {
    add("SIGHTER_HOST_ABI_PROFILE_FILE", options.host_abi_profile);
    result.push_back("SIGHTER_HOST_ABI_CANARY=1");
    result.push_back("SIGHTER_ALLOW_CANDIDATE_HOST_ABI=1");
  }
  return result;
}

}  // namespace

UnsafeLatestRunResult RunUnsafeLatestCandidate(
    const UnsafeLatestRunOptions& options) {
  UnsafeLatestRunResult result;
  if (!IsExecutableRegularFile(options.runtime_binary)) {
    result.error = "unsafe latest runtime is not an executable regular file";
    return result;
  }
  if (!IsRegularFile(options.payload_directory / "libroblox.so")) {
    result.error = "unsafe latest payload library is not a regular file";
    return result;
  }
  if (!IsRegularFile(options.compatibility_manifest)) {
    result.error = "unsafe latest compatibility manifest is not a regular file";
    return result;
  }
  if (!options.host_abi_profile.empty() &&
      !IsRegularFile(options.host_abi_profile)) {
    result.error = "unsafe latest HostAbi profile is not a regular file";
    return result;
  }

  std::vector<std::string> environment = BuildEnvironment(options);
  std::vector<char*> environment_pointers;
  environment_pointers.reserve(environment.size() + 1U);
  for (std::string& entry : environment)
    environment_pointers.push_back(entry.data());
  environment_pointers.push_back(nullptr);

  std::string binary = options.runtime_binary.string();
  char windowed[] = "--windowed";
  char allow_unverified[] = "--allow-unverified-build";
  char* arguments[] = {
      binary.data(), windowed,
      options.host_abi_profile.empty() ? nullptr : allow_unverified, nullptr};
  pid_t child = -1;
  const int spawn_status =
      posix_spawn(&child, options.runtime_binary.c_str(), nullptr, nullptr,
                  arguments, environment_pointers.data());
  if (spawn_status != 0) {
    result.error = "cannot start unsafe latest Roblox: " +
                   std::string(std::strerror(spawn_status));
    return result;
  }

  int status = 0;
  while (waitpid(child, &status, 0) < 0) {
    if (errno == EINTR) continue;
    result.error = "cannot wait for unsafe latest Roblox: " +
                   std::string(std::strerror(errno));
    return result;
  }
  if (!WIFEXITED(status)) {
    result.exit_code = 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
    result.error = "unsafe latest Roblox terminated before a normal exit";
    return result;
  }
  result.exit_code = WEXITSTATUS(status);
  if (result.exit_code != 0) {
    result.error = "unsafe latest Roblox exited with status " +
                   std::to_string(result.exit_code);
  }
  return result;
}

}  // namespace sighter::update

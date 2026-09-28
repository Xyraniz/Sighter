#include "runtime/frame_rate_policy.h"

#define JSON_NOEXCEPTION 1
#include <nlohmann/json.hpp>

#include <charconv>
#include <string>

namespace sighter {
namespace runtime {
namespace {

bool SetCompatibleValue(nlohmann::json *object, const char *key,
                        const std::string &value, std::string *error) {
  const auto existing = object->find(key);
  if (existing != object->end()) {
    if (!existing->is_string() || existing->get<std::string>() != value) {
      if (error != nullptr) {
        *error = std::string("frame-rate policy conflicts with ") + key;
      }
      return false;
    }
    return true;
  }
  (*object)[key] = value;
  return true;
}

} // namespace

FrameRatePolicy ParseFrameRatePolicy(std::string_view value) {
  if (value.empty() || value == "-1") {
    return {};
  }
  if (value == "display") {
    return {FrameRateLimitMode::kDisplay, 0};
  }
  if (value == "unlimited") {
    return {FrameRateLimitMode::kUnlimited, 0};
  }
  int fps = 0;
  const auto parsed =
      std::from_chars(value.data(), value.data() + value.size(), fps);
  if (parsed.ec == std::errc() &&
      parsed.ptr == value.data() + value.size() && fps > 0) {
    return {FrameRateLimitMode::kFixed, fps};
  }
  return {FrameRateLimitMode::kInvalid, 0};
}

bool MergeFrameRateClientSettingsOverrides(const FrameRatePolicy &policy,
                                           std::string_view base_json,
                                           std::string *merged_json,
                                           std::string *error) {
  if (merged_json == nullptr || !policy.valid()) {
    if (error != nullptr) {
      *error = "invalid frame-rate policy";
    }
    return false;
  }
  nlohmann::json overrides = nlohmann::json::parse(
      base_json.empty() ? "{}" : base_json, nullptr, false, true);
  if (overrides.is_discarded() || !overrides.is_object()) {
    if (error != nullptr) {
      *error = "client-settings overrides must be a JSON object";
    }
    return false;
  }
  if (!SetCompatibleValue(&overrides,
                          "FFlagGameBasicSettingsFramerateCap5", "True",
                          error)) {
    return false;
  }
  if (policy.mode == FrameRateLimitMode::kUnmanaged ||
      policy.mode == FrameRateLimitMode::kDisplay) {
    *merged_json = overrides.dump();
    return true;
  }
  const std::string target =
      policy.mode == FrameRateLimitMode::kUnlimited
          ? std::to_string(kMaximumSupportedRobloxSchedulerFps)
          : std::to_string(policy.fixed_fps);
  if (!SetCompatibleValue(&overrides, "DFIntTaskSchedulerTargetFps", target,
                          error)) {
    return false;
  }
  *merged_json = overrides.dump();
  return true;
}

} // namespace runtime
} // namespace sighter

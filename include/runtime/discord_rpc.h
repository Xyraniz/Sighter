#ifndef SIGHTER_RUNTIME_DISCORD_RPC_H_
#define SIGHTER_RUNTIME_DISCORD_RPC_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#include "runtime/roblox_experience_presence.h"
#include "runtime/runtime_config.h"

namespace sighter {
namespace runtime {

struct DiscordRpcActivity {
  std::string details;
  std::string state;
  std::optional<int64_t> start_timestamp;
  std::string large_image;
  std::string large_text;
};

DiscordRpcActivity BuildDiscordRpcActivity(
    const DiscordRpcConfig& config, RobloxExperiencePresencePhase phase,
    std::string place_name, int64_t session_started_at,
    std::string place_icon_url = {});

// Maintains a direct, unauthenticated Discord Desktop RPC connection. The
// worker owns all network and IPC work; lifecycle notifications only replace
// a small in-memory snapshot and never block the Roblox main thread.
class DiscordRpcSession final {
 public:
  explicit DiscordRpcSession(DiscordRpcConfig config);
  ~DiscordRpcSession();

  DiscordRpcSession(const DiscordRpcSession&) = delete;
  DiscordRpcSession& operator=(const DiscordRpcSession&) = delete;

  bool Start(std::string* detail = nullptr);
  void Stop();
  RobloxExperiencePresenceObserver observer();

 private:
  class Impl;
  static void Notify(void* context, RobloxExperiencePresencePhase phase,
                     const RobloxExperienceLaunchRequest* request);

  std::unique_ptr<Impl> impl_;
};

}  // namespace runtime
}  // namespace sighter

#endif  // SIGHTER_RUNTIME_DISCORD_RPC_H_

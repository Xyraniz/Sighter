#ifndef SIGHTER_WINDOW_VIDEO_DRIVER_POLICY_H_
#define SIGHTER_WINDOW_VIDEO_DRIVER_POLICY_H_

#include <string_view>
#include <vector>

namespace sighter {
namespace window {

enum class VideoDriverChoice {
  kSdlDefault,
  kWayland,
  kX11,
  kNvidiaDirectVulkanX11,
};

struct VideoDriverPolicyInput {
  bool has_explicit_sdl_driver = false;
  bool force_wayland = false;
  bool force_x11 = false;
  bool prefer_wayland = true;
  bool has_wayland_session = false;
  bool has_x11_display = false;
  bool uses_direct_vulkan = false;
  bool has_nvidia_kernel_driver = false;
};

// Resolves the SDL video backend before SDL_Init. An explicit SDL driver is
// always authoritative. NVIDIA's direct Vulkan WSI uses X11/XWayland by
// default when both display transports are available because a blocked native
// Wayland present cannot be cancelled without violating VkQueue ownership.
VideoDriverChoice ResolveVideoDriverChoice(const VideoDriverPolicyInput& input);

const char* VideoDriverChoiceName(VideoDriverChoice choice);

// SDL accepts a comma-separated priority list. An inherited override is only
// useful when at least one requested driver exists in the linked SDL build.
bool HasAvailableVideoDriverCandidate(
    std::string_view requested,
    const std::vector<std::string_view>& available_drivers);

}  // namespace window
}  // namespace sighter

#endif  // SIGHTER_WINDOW_VIDEO_DRIVER_POLICY_H_

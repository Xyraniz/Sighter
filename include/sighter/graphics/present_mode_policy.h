#ifndef SIGHTER_GRAPHICS_PRESENT_MODE_POLICY_H_
#define SIGHTER_GRAPHICS_PRESENT_MODE_POLICY_H_

#include <cstdint>
#include <string_view>
#include <vector>

#include <vulkan/vulkan.h>

namespace sighter {
namespace graphics {

enum class PresentModePolicy {
  kHostDefault,
  kVsync,
  kUnthrottled,
};

PresentModePolicy ResolvePresentModePolicy(std::string_view vsync_value,
                                           std::string_view frame_rate_value);

// Reads SIGHTER_VSYNC / SIGHTER_FRAME_RATE_LIMIT once. Window pacing and
// the Vulkan adapter must use this instead of getenv'ing the same keys.
PresentModePolicy CachedPresentModePolicy();

std::vector<VkPresentModeKHR>
FilterPresentModes(PresentModePolicy policy,
                   const std::vector<VkPresentModeKHR> &host_modes);
const char *PresentModePolicyName(PresentModePolicy policy);
const char *PresentModeKhrName(VkPresentModeKHR mode);

// Extra images so acquire does not wait on the compositor-held buffer.
std::uint32_t PreferSwapchainMinImageCount(PresentModePolicy policy,
                                           std::uint32_t requested,
                                           std::uint32_t min_images,
                                           std::uint32_t max_images);

} // namespace graphics
} // namespace sighter

#endif // SIGHTER_GRAPHICS_PRESENT_MODE_POLICY_H_

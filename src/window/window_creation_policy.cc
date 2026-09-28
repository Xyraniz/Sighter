#include "window/window_creation_policy.h"

namespace sighter {
namespace window {

SDL_WindowFlags ApplyHighPixelDensityWindowFlag(SDL_WindowFlags flags,
                                                bool high_dpi) {
  if (high_dpi) {
    return flags | SDL_WINDOW_HIGH_PIXEL_DENSITY;
  }
  return flags & ~SDL_WINDOW_HIGH_PIXEL_DENSITY;
}

bool DirectVulkanWindowRequiresInitialSync(std::string_view video_driver) {
  return video_driver == "wayland";
}

}  // namespace window
}  // namespace sighter

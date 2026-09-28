#ifndef SIGHTER_WINDOW_WINDOW_CREATION_POLICY_H_
#define SIGHTER_WINDOW_WINDOW_CREATION_POLICY_H_

#include <SDL3/SDL_video.h>

#include <string_view>

namespace sighter {
namespace window {

SDL_WindowFlags ApplyHighPixelDensityWindowFlag(SDL_WindowFlags flags,
                                                bool high_dpi);

// Native Wayland surfaces must receive their initial configure before Vulkan
// can reliably query the surface extent. X11/XWayland windows do not have
// that requirement, and waiting for an asynchronous window-manager state
// change (for example, restored maximization) can time out even though the
// X11 window is already usable.
bool DirectVulkanWindowRequiresInitialSync(std::string_view video_driver);

}  // namespace window
}  // namespace sighter

#endif  // SIGHTER_WINDOW_WINDOW_CREATION_POLICY_H_

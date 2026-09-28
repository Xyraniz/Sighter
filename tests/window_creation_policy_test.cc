#include "window/window_creation_policy.h"

#include <gtest/gtest.h>

namespace sighter {
namespace window {
namespace {

TEST(WindowCreationPolicyTest, DisablesHighDensityForEveryWindowBackend) {
  for (const SDL_WindowFlags base_flags : {
           static_cast<SDL_WindowFlags>(0),
           SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE,
           SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE,
       }) {
    const SDL_WindowFlags flags =
        ApplyHighPixelDensityWindowFlag(base_flags, false);
    EXPECT_EQ(flags & SDL_WINDOW_HIGH_PIXEL_DENSITY, 0);
    EXPECT_EQ(flags, base_flags);
  }
}

TEST(WindowCreationPolicyTest, EnablesHighDensityForEveryWindowBackend) {
  for (const SDL_WindowFlags base_flags : {
           static_cast<SDL_WindowFlags>(0),
           SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE,
           SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE,
       }) {
    const SDL_WindowFlags flags =
        ApplyHighPixelDensityWindowFlag(base_flags, true);
    EXPECT_NE(flags & SDL_WINDOW_HIGH_PIXEL_DENSITY, 0);
    EXPECT_EQ(flags & ~SDL_WINDOW_HIGH_PIXEL_DENSITY, base_flags);
  }
}

TEST(WindowCreationPolicyTest, SynchronizesInitialDirectVulkanWaylandMap) {
  EXPECT_TRUE(DirectVulkanWindowRequiresInitialSync("wayland"));
}

TEST(WindowCreationPolicyTest, DoesNotSynchronizeInitialX11Map) {
  EXPECT_FALSE(DirectVulkanWindowRequiresInitialSync("x11"));
  EXPECT_FALSE(DirectVulkanWindowRequiresInitialSync("dummy"));
  EXPECT_FALSE(DirectVulkanWindowRequiresInitialSync(""));
}

}  // namespace
}  // namespace window
}  // namespace sighter

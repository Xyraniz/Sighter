#ifndef SIGHTER_PLATFORM_SDL_PLATFORM_RUNTIME_H_
#define SIGHTER_PLATFORM_SDL_PLATFORM_RUNTIME_H_

#include <memory>

#include "sighter/platform/platform_runtime.h"

namespace sighter {
namespace platform {

// Creates an SDL3-backed runtime without exposing SDL types to consumers.
std::unique_ptr<PlatformRuntime> CreateSdlPlatformRuntime();

}  // namespace platform
}  // namespace sighter

#endif  // SIGHTER_PLATFORM_SDL_PLATFORM_RUNTIME_H_

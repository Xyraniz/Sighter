#ifndef SIGHTER_PLATFORM_SDL_APPLICATION_METADATA_H_
#define SIGHTER_PLATFORM_SDL_APPLICATION_METADATA_H_

#include "sighter/status.h"

namespace sighter {
namespace platform {

inline constexpr char kSighterApplicationName[] = "Sighter";
inline constexpr char kSighterApplicationIdentifier[] =
    "space.bigrat.sighter";

// Configures the stable compositor identity before SDL initializes. The
// identifier matches the installed desktop file and icon name so Wayland and
// X11 compositors can group the runtime window with its launcher.
Status ConfigureSdlApplicationMetadata();

}  // namespace platform
}  // namespace sighter

#endif  // SIGHTER_PLATFORM_SDL_APPLICATION_METADATA_H_

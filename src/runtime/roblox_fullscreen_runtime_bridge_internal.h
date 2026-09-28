#ifndef SIGHTER_RUNTIME_ROBLOX_FULLSCREEN_RUNTIME_BRIDGE_INTERNAL_H_
#define SIGHTER_RUNTIME_ROBLOX_FULLSCREEN_RUNTIME_BRIDGE_INTERNAL_H_

#include <cstddef>
#include <cstdint>

namespace sighter {
namespace runtime {
namespace internal {

// Verifies the stable semantic instructions of the current setter without
// depending on relocation-specific call displacements.
bool HasExpectedFullscreenSetterContract(const std::uint8_t* code,
                                         std::size_t size);

}  // namespace internal
}  // namespace runtime
}  // namespace sighter

#endif  // SIGHTER_RUNTIME_ROBLOX_FULLSCREEN_RUNTIME_BRIDGE_INTERNAL_H_

#ifndef SIGHTER_AUDIO_OPENSL_PLAYBACK_RUNTIME_H_
#define SIGHTER_AUDIO_OPENSL_PLAYBACK_RUNTIME_H_

#include <cstdint>

#include "sighter/audio/opensl_runtime_abi.h"

#if defined(__GNUC__) || defined(__clang__)
#define SIGHTER_OPENSL_EXPORT __attribute__((visibility("default")))
#else
#define SIGHTER_OPENSL_EXPORT
#endif

// Process-wide, content-free evidence from the production OpenSL boundary.
// Counters contain no audio samples, filenames, account data, or device names.
struct SighterOpenSlRuntimeStats {
  std::uint64_t submitted_buffers;
  std::uint64_t consumed_buffers;
  std::uint64_t clean_player_shutdowns;
};

extern "C" {

#if !defined(SIGHTER_USE_SYSTEM_OPENSL_HEADERS)
extern SIGHTER_OPENSL_EXPORT const
    sighter::audio::opensl_abi::InterfaceId SL_IID_ANDROIDCONFIGURATION;
extern SIGHTER_OPENSL_EXPORT const
    sighter::audio::opensl_abi::InterfaceId SL_IID_ANDROIDSIMPLEBUFFERQUEUE;
extern SIGHTER_OPENSL_EXPORT const
    sighter::audio::opensl_abi::InterfaceId SL_IID_BUFFERQUEUE;
extern SIGHTER_OPENSL_EXPORT const
    sighter::audio::opensl_abi::InterfaceId SL_IID_ENGINE;
extern SIGHTER_OPENSL_EXPORT const
    sighter::audio::opensl_abi::InterfaceId SL_IID_PLAY;
extern SIGHTER_OPENSL_EXPORT const
    sighter::audio::opensl_abi::InterfaceId SL_IID_RECORD;
extern SIGHTER_OPENSL_EXPORT const
    sighter::audio::opensl_abi::InterfaceId SL_IID_VOLUME;

SIGHTER_OPENSL_EXPORT sighter::audio::opensl_abi::Result
SIGHTER_OPENSL_API_ENTRY slCreateEngine(
    sighter::audio::opensl_abi::Object* engine,
    sighter::audio::opensl_abi::Uint32 num_options,
    const sighter::audio::opensl_abi::EngineOption* options,
    sighter::audio::opensl_abi::Uint32 num_interfaces,
    const sighter::audio::opensl_abi::InterfaceId* interface_ids,
    const sighter::audio::opensl_abi::Boolean* interface_required);
#endif

SIGHTER_OPENSL_EXPORT sighter::audio::opensl_abi::Result
sighterOpenSlGetRuntimeStats(SighterOpenSlRuntimeStats* stats,
                              std::uint32_t stats_size);

}  // extern "C"

#endif  // SIGHTER_AUDIO_OPENSL_PLAYBACK_RUNTIME_H_

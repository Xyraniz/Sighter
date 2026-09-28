#ifndef SIGHTER_AUDIO_SDL_AUDIO_SINK_H_
#define SIGHTER_AUDIO_SDL_AUDIO_SINK_H_

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "sighter/audio/audio_sink.h"

namespace sighter::audio {

// SDL requires subsystem startup and shutdown on the main thread.
Status InitializeSdlAudioSubsystem();
Status ShutdownSdlAudioSubsystem();

struct SdlPlaybackDevice {
  std::uint32_t id = 0;
  std::string name;
};

// The virtual `default` target is not returned.
Status ListSdlPlaybackDevices(std::vector<SdlPlaybackDevice>* devices);

Status ResolveSdlPlaybackDevice(
    std::string_view requested,
    const std::vector<SdlPlaybackDevice>& available_devices,
    std::uint32_t* playback_device_id, std::string* resolved_name);

// Must run after SDL audio initialization and before the first sink opens.
Status ConfigureSdlPlaybackDevice(
    std::string_view requested,
    std::vector<SdlPlaybackDevice>* available_devices,
    std::string* resolved_name);

// Device ID zero means the system default.
Status GetConfiguredSdlPlaybackDevice(std::uint32_t* playback_device_id,
                                      std::string* resolved_name);

// Migrates live streams without dropping queued PCM. New sinks inherit it.
Status SwitchSdlPlaybackDevice(std::uint32_t playback_device_id,
                               std::string* resolved_name);

struct SdlAudioSinkOptions {
  PcmSpec source_spec;

  // Zero selects the configured process target.
  std::uint32_t playback_device_id = 0;
  bool start_paused = true;

  // Optional pull provider for the host device. Each call fills one source
  // buffer whose address remains valid until the next provider call. SDL
  // copies as many buffers as the current device request needs.
  bool (*data_needed_callback)(void *context, const void **data,
                               std::size_t *size_bytes) = nullptr;
  void *data_needed_context = nullptr;
};

// SDL owns conversion, resampling, and borrowed-buffer consumption.
Status CreateSdlAudioSink(const SdlAudioSinkOptions& options,
                          std::unique_ptr<AudioSink>* sink);

}  // namespace sighter::audio

#endif  // SIGHTER_AUDIO_SDL_AUDIO_SINK_H_

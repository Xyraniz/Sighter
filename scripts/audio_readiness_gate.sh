#!/usr/bin/env bash

# Copyright 2026 Sighter Project Authors
# Licensed under the Apache License, Version 2.0.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <completed-runtime-log>" >&2
  exit 2
fi

readonly log_path="$1"
if [[ ! -f "${log_path}" ]]; then
  echo "audio readiness log is not a regular file: ${log_path}" >&2
  exit 2
fi

readonly activity_pattern='\[sighter\]\[audio\] OpenSL playback activity: submitted_buffers=[1-9][0-9]*'
readonly consumption_pattern='\[sighter\]\[audio\] OpenSL playback evidence: consumed_buffers=[1-9][0-9]*'
readonly emitted_shutdown_pattern='\[sighter\]\[audio\] OpenSL player shutdown: submitted=[1-9][0-9]* .*clean=true'
readonly unclean_shutdown_pattern='\[sighter\]\[audio\] OpenSL player shutdown: submitted=[1-9][0-9]* .*clean=false'
readonly fmod_activity_pattern='\[sighter\]\[audio\] fmod_java first_submission submitted_buffers=[1-9][0-9]*'
readonly fmod_consumption_pattern='\[sighter\]\[audio\] fmod_java (closed|shutdown) .*consumed_buffers=[1-9][0-9]*'
readonly fmod_shutdown_pattern='\[sighter\]\[audio\] fmod_java shutdown submitted_buffers=[1-9][0-9]* .*consumed_buffers=[1-9][0-9]* .*pending_buffers=0'
readonly fmod_failure_pattern='\[sighter\]\[audio\] fmod_java (init|write|close)_failed'
readonly window_shutdown_pattern='\[window\] Shutdown window='

opensl_emitted=0
fmod_emitted=0
if rg -q "${activity_pattern}" "${log_path}"; then
  opensl_emitted=1
fi
if rg -q "${fmod_activity_pattern}" "${log_path}"; then
  fmod_emitted=1
fi
if rg -q "${fmod_failure_pattern}" "${log_path}"; then
  echo "FMOD Java audio reported a rejected lifecycle or PCM write" >&2
  exit 1
fi

# Opening an audio player is not evidence that the payload emitted PCM. Audio
# remains optional when no buffer crossed the guest boundary.
if (( opensl_emitted == 0 && fmod_emitted == 0 )); then
  if rg -q "${consumption_pattern}|${fmod_consumption_pattern}" "${log_path}"; then
    echo "audio readiness evidence is inconsistent: consumption without submission" >&2
    exit 1
  fi
  echo "audio_status=not_emitted"
  exit 0
fi

if (( opensl_emitted != 0 )); then
  if ! rg -q "${consumption_pattern}" "${log_path}"; then
    echo "payload submitted OpenSL audio but SDL consumed no buffer" >&2
    exit 1
  fi
  if rg -q "${unclean_shutdown_pattern}" "${log_path}"; then
    echo "an audio-emitting OpenSL player did not shut down cleanly" >&2
    exit 1
  fi
  if ! rg -q "${emitted_shutdown_pattern}" "${log_path}"; then
    echo "audio-emitting OpenSL player has no clean shutdown evidence" >&2
    exit 1
  fi
fi

if (( fmod_emitted != 0 )); then
  if ! rg -q "${fmod_consumption_pattern}" "${log_path}"; then
    echo "payload submitted FMOD Java audio but SDL consumed no buffer" >&2
    exit 1
  fi
  if ! rg -q "${fmod_shutdown_pattern}" "${log_path}"; then
    echo "audio-emitting FMOD Java runtime has no clean shutdown evidence" >&2
    exit 1
  fi
  if rg -q "${window_shutdown_pattern}" "${log_path}"; then
    fmod_shutdown_line="$(rg -n "${fmod_shutdown_pattern}" "${log_path}" | tail -1 | cut -d: -f1)"
    window_shutdown_line="$(rg -n "${window_shutdown_pattern}" "${log_path}" | head -1 | cut -d: -f1)"
    if (( fmod_shutdown_line >= window_shutdown_line )); then
      echo "FMOD/SDL audio must shut down before the window calls SDL_Quit" >&2
      exit 1
    fi
  fi
fi

echo "audio_status=consumed_and_shutdown_cleanly"

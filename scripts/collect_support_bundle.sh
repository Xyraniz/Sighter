#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

set -Eeuo pipefail
umask 077

# Diagnostics must not inherit shell/tool injection controls from the failed
# process. Keep command lookup deterministic; display/session variables that
# Vulkan needs are retained separately in the environment.
unset BASH_ENV ENV TAR_OPTIONS GZIP BZIP2 BZIP GZIP_OPT ZSTD_CLEVEL \
  AWKPATH AWKLIBPATH PERL5OPT PERL5LIB PYTHONPATH RUBYOPT CDPATH \
  GREP_OPTIONS POSIXLY_CORRECT LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT
unset -f env tar gzip awk tail find sort cut grep sed head date uname mktemp stat \
  chmod mkdir mv rm jq timeout vulkaninfo 2>/dev/null || true
export PATH=/usr/bin:/bin
export LC_ALL=C

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -P -- "${SCRIPT_DIR}/.." && pwd)"
DATA_ROOT="${SIGHTER_DATA_ROOT:-${XDG_DATA_HOME:-${HOME}/.local/share}/sighter}"
CACHE_ROOT="${SIGHTER_CACHE_ROOT:-${XDG_CACHE_HOME:-${HOME}/.cache}/sighter}"
STATE_ROOT="${SIGHTER_STATE_ROOT:-${XDG_STATE_HOME:-${HOME}/.local/state}/sighter}"
CONFIG_ROOT="${SIGHTER_CONFIG_ROOT:-${XDG_CONFIG_HOME:-${HOME}/.config}/sighter}"
AUTH_ROOT="${SIGHTER_AUTH_ROOT:-${DATA_ROOT}/auth}"
OUTPUT_ROOT="${SIGHTER_SUPPORT_OUTPUT_ROOT:-${STATE_ROOT}/support}"
CONTEXT=manual
REASON=manual-request
EXIT_CODE=unknown
SOURCE_LOG=""
SOURCE_LOG_FD=""
PAYLOAD_METADATA=""
MAX_LOG_BYTES="${SIGHTER_SUPPORT_MAX_LOG_BYTES:-262144}"
MAX_BUNDLES="${SIGHTER_SUPPORT_MAX_BUNDLES:-5}"
WORK_ROOT=""
ARCHIVE_TEMP=""

Usage() {
  cat <<'EOF'
Usage: scripts/collect_support_bundle.sh [OPTIONS]

Create a private, sanitized Sighter support archive.

Options:
  --context NAME     Failure source: launch, readiness, updater, or manual.
  --reason NAME      Non-sensitive machine-readable failure reason.
  --exit-code CODE   Process exit code, signal form, or unknown.
  --log FILE         Include a bounded, sanitized operational log excerpt.
  --payload-metadata FILE
                     Use an exact candidate roblox_payload.json instead of
                     the active payload manifest.
  --output-dir DIR   Override the private archive directory.
  -h, --help         Show this help.

The archive never copies config files, cookies, authentication state, raw
environment variables, APKs, or native payload contents.
EOF
}

Die() {
  printf 'sighter-support: %s\n' "$*" >&2
  exit 1
}

Cleanup() {
  [[ -z "${WORK_ROOT}" ]] || rm -rf -- "${WORK_ROOT}"
  [[ -z "${ARCHIVE_TEMP}" ]] || rm -f -- "${ARCHIVE_TEMP}"
}

SafeToken() {
  local value="$1"
  local fallback="$2"
  if [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._:+-]{0,63}$ ]]; then
    printf '%s' "${value}"
  else
    printf '%s' "${fallback}"
  fi
}

AllowlistedToken() {
  local value="$1"
  local fallback="$2"
  shift 2
  local allowed
  for allowed in "$@"; do
    if [[ "${value}" == "${allowed}" ]]; then
      printf '%s' "${value}"
      return 0
    fi
  done
  printf '%s' "${fallback}"
}

SessionTypeToken() {
  AllowlistedToken "$1" unknown x11 wayland tty unspecified unknown
}

VideoDriverToken() {
  AllowlistedToken "$1" unknown auto x11 wayland kmsdrm offscreen dummy
}

GraphicsBackendToken() {
  AllowlistedToken "$1" unknown auto system system-egl gles opengl vulkan \
    native-vulkan direct-vulkan angle-vulkan angle-swiftshader
}

AudioBackendToken() {
  AllowlistedToken "$1" unknown auto pipewire pulseaudio alsa jack sndio dsp \
    disk dummy opensl fmod_java fmod-java sdl sdl3
}

YesNo() {
  [[ -n "$1" ]] && printf yes || printf no
}

ParseArguments() {
  while (( $# > 0 )); do
    case "$1" in
      --context)
        (( $# >= 2 )) || Die "--context requires a value"
        CONTEXT="$2"
        shift 2
        ;;
      --reason)
        (( $# >= 2 )) || Die "--reason requires a value"
        REASON="$2"
        shift 2
        ;;
      --exit-code)
        (( $# >= 2 )) || Die "--exit-code requires a value"
        EXIT_CODE="$2"
        shift 2
        ;;
      --log)
        (( $# >= 2 )) || Die "--log requires a path"
        SOURCE_LOG="$2"
        shift 2
        ;;
      --payload-metadata)
        (( $# >= 2 )) || Die "--payload-metadata requires a path"
        PAYLOAD_METADATA="$2"
        shift 2
        ;;
      --output-dir)
        (( $# >= 2 )) || Die "--output-dir requires a path"
        OUTPUT_ROOT="$2"
        shift 2
        ;;
      -h|--help)
        Usage
        exit 0
        ;;
      *) Die "unknown option: $1" ;;
    esac
  done

  case "${CONTEXT}" in
    launch|readiness|updater|manual) ;;
    *) Die "unsupported context: ${CONTEXT}" ;;
  esac
  CONTEXT="$(SafeToken "${CONTEXT}" unknown)"
  REASON="$(SafeToken "${REASON}" unspecified)"
  if [[ "${EXIT_CODE}" != unknown &&
        ! "${EXIT_CODE}" =~ ^([0-9]{1,3}|signal-[0-9]{1,2})$ ]]; then
    Die "invalid exit code"
  fi
  [[ "${MAX_LOG_BYTES}" =~ ^[1-9][0-9]{3,6}$ ]] &&
    (( 10#${MAX_LOG_BYTES} <= 1048576 )) ||
    Die "SIGHTER_SUPPORT_MAX_LOG_BYTES must be between 1000 and 1048576"
  [[ "${MAX_BUNDLES}" =~ ^[1-9][0-9]?$ ]] &&
    (( 10#${MAX_BUNDLES} <= 20 )) ||
    Die "SIGHTER_SUPPORT_MAX_BUNDLES must be between 1 and 20"
  [[ "${OUTPUT_ROOT}" == /* ]] || Die "output directory must be absolute"

  if [[ -n "${SOURCE_LOG}" ]]; then
    [[ -f "${SOURCE_LOG}" && ! -L "${SOURCE_LOG}" && -r "${SOURCE_LOG}" ]] ||
      Die "source log must be a readable regular non-symlink file"
    exec {SOURCE_LOG_FD}<"${SOURCE_LOG}" || Die "cannot open source log"
    [[ "$(stat -Lc '%F' "/proc/self/fd/${SOURCE_LOG_FD}" 2>/dev/null)" == \
       "regular file" ]] || Die "opened source log is not a regular file"
  fi
  if [[ -n "${PAYLOAD_METADATA}" ]]; then
    [[ -f "${PAYLOAD_METADATA}" && ! -L "${PAYLOAD_METADATA}" &&
       -r "${PAYLOAD_METADATA}" ]] ||
      Die "payload metadata must be a readable regular non-symlink file"
  fi
}

SanitizeLog() {
  local source="$1"
  local destination="$2"
  tail -c "${MAX_LOG_BYTES}" -- "${source}" |
    awk '
      function safe_token_after(value, marker, result) {
        result = value
        sub("^.*" marker, "", result)
        sub(/[[:space:]].*$/, "", result)
        if (length(result) < 1 || length(result) > 64 ||
            result !~ /^[A-Za-z0-9][A-Za-z0-9._:+-]*$/) return ""
        return result
      }
      function updater_error_category(value) {
        if (value ~ /(already running|lock)/) return "lock"
        if (value ~ /(jq|timeout|flock|required)/) return "dependency"
        if (value ~ /(config|source|scheduled|option|argument)/) return "configuration"
        if (value ~ /(auth|google play)/) return "authentication"
        if (value ~ /(provider|fetch|download|network)/) return "download"
        if (value ~ /(canary|vulkan|present)/) return "canary"
        if (value ~ /(promot|rollback|fingerprint|current payload)/) return "promotion"
        if (value ~ /(validator|apk|x86|metadata|manifest|build id|payload)/) {
          return "payload-validation"
        }
        if (value ~ /(build|binary|cmake|compiler)/) return "runtime-build"
        return "operation"
      }
      function known_video_driver(value) {
        return value ~ /^(auto|x11|wayland|kmsdrm|offscreen|dummy)$/
      }
      function known_graphics_backend(value) {
        return value ~ /^(auto|system|system-egl|gles|opengl|vulkan|native-vulkan|direct-vulkan|angle-vulkan|angle-swiftshader)$/
      }
      function known_audio_backend(value) {
        return value ~ /^(auto|pipewire|pulseaudio|alsa|jack|sndio|dsp|disk|dummy|opensl|fmod_java|fmod-java|sdl|sdl3)$/
      }
      {
        line = $0
        lower = tolower(line)

        # Never copy a tagged line wholesale. Only emit canonical events from
        # a small grammar so a future log message cannot turn a
        # user name, window title, device label, URL, or token into telemetry.
        if (line ~ /^[[:space:]]*\[FATAL\]/) {
          if (lower ~ /compat/) print "[FATAL] compatibility failure"
          else if (lower ~ /(payload|build id|load)/) print "[FATAL] payload load failure"
          else if (lower ~ /(vulkan|graphics|window|surface)/) print "[FATAL] graphics failure"
          else if (lower ~ /audio/) print "[FATAL] audio failure"
          else if (lower ~ /(auth|identity)/) print "[FATAL] authentication failure"
          else if (lower ~ /(config|policy)/) print "[FATAL] configuration failure"
          else print "[FATAL] runtime failure"
          next
        }
        if (line ~ /(Segmentation fault|dumped core)/) {
          print "[crash] fatal signal observed"
          next
        }
        if (line ~ /^[[:space:]]*(timeout:|Aborted$)/) {
          print "[crash] bounded process failure"
          next
        }
        if (lower ~ /(disconnect reason received|disconnection notification\. reason):[[:space:]]*319([^0-9]|$)/) {
          print "[network] remote attestation timeout disconnect=319"
          next
        }
        if (lower ~ /roblox was not able to verify the integrity of the game/ ||
            lower ~ /this place (has enabled additional hardware security requirements|requires a trusted operating system)/) {
          print "[network] remote attestation rejected"
          next
        }
        if (line ~ /^[[:space:]]*\[auto-update\]/) {
          if (lower ~ /error:/) {
            print "[auto-update] error category=" updater_error_category(lower)
          } else if (lower ~ /failed canary/) {
            print "[auto-update] canary failed"
          } else if (lower ~ /running isolated real vulkan.*canary/) {
            print "[auto-update] canary started"
          } else if (lower ~ /awaits a supported build-id profile/) {
            print "[auto-update] unsupported Build ID staged"
          } else if (lower ~ /canarying newest exact-supported staged fallback/) {
            print "[auto-update] exact-supported staged fallback selected"
          } else if (lower ~ /update available/) {
            print "[auto-update] provider reports a newer version"
          } else if (lower ~ /downloading provider payload/) {
            print "[auto-update] download started"
          } else if (lower ~ /validating downloaded x86_64 payload/) {
            print "[auto-update] payload validation started"
          } else if (lower ~ /building canary runtime/) {
            print "[auto-update] runtime build started"
          } else if (lower ~ /fingerprinting candidate payload/) {
            print "[auto-update] payload fingerprint started"
          } else if (lower ~ /promoting canary-approved candidate/) {
            print "[auto-update] promotion started"
          } else if (lower ~ /passed canary and is now current/) {
            print "[auto-update] candidate promoted"
          } else if (lower ~ /rolling back/) {
            print "[auto-update] promotion rollback started"
          } else if (lower ~ /was not promoted/) {
            print "[auto-update] promotion rejected"
          } else if (lower ~ /refusing to remove provider bundle/) {
            print "[auto-update] managed staging cleanup refused"
          }
          next
        }
        if (line ~ /\[window\] graphics backend=/) {
          graphics_backend = safe_token_after(line, "graphics backend=")
          video_driver = safe_token_after(line, "video=")
          if (known_graphics_backend(graphics_backend) &&
              known_video_driver(video_driver)) {
            print "[window] graphics backend=" graphics_backend " video=" video_driver
          }
          next
        }
        if (line ~ /\[window\] first Roblox Vulkan frame presented/) {
          print "[window] first Roblox Vulkan frame presented"
          next
        }
        if (line ~ /JNI_OnLoad/) {
          if (lower ~ /returned/) print "[startup] JNI_OnLoad returned"
          else if (lower ~ /timeout/) print "[startup] JNI_OnLoad timeout"
          else if (lower ~ /(invoking|calling)/) print "[startup] JNI_OnLoad invoked"
          next
        }
        if (line ~ /\[compat\]/) {
          if (line ~ /Build ID/ && lower ~ /(supported|unverified|unsupported)/) {
            if (lower ~ /unsupported/) print "[compat] Build ID status=unsupported"
            else if (lower ~ /unverified/) print "[compat] Build ID status=unverified"
            else print "[compat] Build ID status=supported"
          } else if (lower ~ /host abi profile: allowed/) {
            print "[compat] host ABI profile allowed"
          } else if (lower ~ /constructor replay: allowed/) {
            print "[compat] constructor replay allowed"
          } else if (lower ~ /legacy binary patches: disabled/) {
            print "[compat] legacy binary patches disabled"
          } else if (lower ~ /signal-recovery handler disabled/) {
            print "[compat] signal recovery disabled"
          } else if (lower ~ /(wrapped [0-9]+ constructors|wrapping \.init_array)/) {
            print "[compat] constructor replay configured"
          }
          next
        }
        if (line ~ /\[sighter\]\[audio\]/) {
          if (lower ~ /(init_failed|write_failed|close_failed|shutdown blocked| failure| failed)/) {
            print "[sighter][audio] failure"
          } else if (lower ~ /opensl player shutdown/ &&
                     lower ~ /clean=true/) {
            print "[sighter][audio] shutdown pending_buffers=0"
          } else if (lower ~ /opensl player shutdown/ &&
                     lower ~ /clean=false/) {
            print "[sighter][audio] failure"
          } else if (lower ~ /(shutdown|closed)/) {
            if (lower ~ /pending_buffers=0/) {
              print "[sighter][audio] shutdown pending_buffers=0"
            } else {
              print "[sighter][audio] shutdown pending_buffers=nonzero"
            }
          } else if (lower ~ /(initialized|realized|first_submission)/) {
            print "[sighter][audio] initialized"
          } else if (line ~ / backend=/) {
            audio_backend = safe_token_after(line, "backend=")
            if (known_audio_backend(audio_backend)) {
              print "[sighter][audio] backend=" audio_backend
            }
          }
          next
        }
        if (line ~ /\[audio-menu\]/) next
        if (line ~ /\[main\]/ && lower ~ /audio shutdown blocked/) {
          print "[sighter][audio] failure"
          next
        }
        if (line ~ /\[input\]/) {
          if (lower ~ /typed production input ready/) {
            print "[input] typed production input ready"
          } else if (lower ~ /typed production input stopped/) {
            print "[input] typed production input stopped"
          } else if (lower ~ /(failed|rejected|terminal)/) {
            print "[input] failed"
          }
          next
        }
        if (line ~ /\[main\] Roblox lifecycle shutdown: Stopped/) {
          print "[main] Roblox lifecycle shutdown: Stopped"
          next
        }
        if (line ~ /\[lifecycle\]/) {
          if (lower ~ /(failed|error)/) print "[lifecycle] failed"
          else if (lower ~ /(stopped|shutdown complete)/) print "[lifecycle] stopped"
          next
        }
        if (line ~ /setStage:[[:space:]]*\(stage:/) {
          stage = line
          sub(/^.*stage:/, "", stage)
          sub(/[^A-Za-z].*$/, "", stage)
          if (stage ~ /^(Native|InitializedLuaApp|LuaApp|UGCGame|None)$/) {
            print "setStage: (stage:" stage ")"
          }
          next
        }
        if (line ~ /RenderView created/) {
          print "[graphics] RenderView created"
          next
        }
        if (line ~ /RenderView destroyed/) {
          print "[graphics] RenderView destroyed"
          next
        }
        if (line ~ /\[vulkan\]/) {
          if (lower ~ /(failed|error)/) print "[vulkan] failed"
          else if (lower ~ /(adapter ready|wsi.*ready)/) print "[vulkan] WSI adapter ready"
          else if (lower ~ /(shut down|shutdown)/) print "[vulkan] WSI adapter shut down"
          next
        }
        if (line ~ /\[surface\]/ && lower ~ /(failed|error)/) {
          print "[surface] failed"
          next
        }
        if (line ~ /UgcExperienceController/ && lower ~ /did not finalize/) {
          print "[lifecycle] UGC finalization incomplete"
        }
      }
    ' >"${destination}"
}

WritePayloadSummary() {
  local destination="$1"
  local manifest="${DATA_ROOT}/current.json" payload_status=active
  if [[ -n "${PAYLOAD_METADATA}" ]]; then
    manifest="${PAYLOAD_METADATA}"
    payload_status=candidate
  fi
  local version_name="" version_code="" build_id="" payload_id=""
  if command -v jq >/dev/null 2>&1 &&
     [[ -f "${manifest}" && ! -L "${manifest}" ]]; then
    version_name="$(jq -er '.version_name | select(type == "string")' \
      "${manifest}" 2>/dev/null || true)"
    version_code="$(jq -er '.version_code | select(type == "number")' \
      "${manifest}" 2>/dev/null || true)"
    build_id="$(jq -er '.elf_build_id | select(type == "string") | ascii_downcase | select(test("^[0-9a-f]{40}$"))' \
      "${manifest}" 2>/dev/null || true)"
    payload_id="$(jq -er '.payload_id | select(type == "string") | select(test("^[0-9]+-[0-9a-f]{40}$"))' \
      "${manifest}" 2>/dev/null || true)"
    if [[ "${payload_status}" == candidate && -n "${version_code}" &&
          -n "${build_id}" ]]; then
      payload_id="${version_code}-${build_id}"
    fi
  fi
  {
    if [[ "${version_name}" =~ ^[0-9]+(\.[0-9]+){2,3}$ &&
          -n "${version_code}" &&
          -n "${build_id}" &&
          "${payload_id}" == "${version_code}-${build_id}" ]]; then
      printf 'status=%s\n' "${payload_status}"
      printf 'version_name=%s\n' "$(SafeToken "${version_name}" invalid)"
      printf 'version_code=%s\n' "${version_code}"
      printf 'elf_build_id=%s\n' "${build_id}"
      printf 'payload_id=%s\n' "${payload_id}"
    else
      printf 'status=unavailable\n'
    fi
  } >"${destination}"
}

WriteRuntimeSummary() {
  local destination="$1"
  local session_type video_driver graphics_backend audio_driver
  session_type="$(SessionTypeToken "${XDG_SESSION_TYPE:-unknown}")"
  video_driver="$(VideoDriverToken "${SDL_VIDEODRIVER:-auto}")"
  graphics_backend="$(GraphicsBackendToken \
    "${SIGHTER_GRAPHICS_BACKEND:-auto}")"
  audio_driver="$(AudioBackendToken "${SDL_AUDIODRIVER:-auto}")"
  {
    printf 'schema=1\n'
    printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'context=%s\n' "${CONTEXT}"
    printf 'reason=%s\n' "${REASON}"
    printf 'exit_code=%s\n' "${EXIT_CODE}"
    printf 'kernel_name=%s\n' "$(SafeToken "$(uname -s 2>/dev/null || true)" unknown)"
    printf 'kernel_release=%s\n' "$(SafeToken "$(uname -r 2>/dev/null || true)" unknown)"
    printf 'architecture=%s\n' "$(SafeToken "$(uname -m 2>/dev/null || true)" unknown)"
    printf 'session_type=%s\n' "${session_type}"
    printf 'display_available=%s\n' "$(YesNo "${DISPLAY:-}")"
    printf 'wayland_display_available=%s\n' "$(YesNo "${WAYLAND_DISPLAY:-}")"
    printf 'sdl_video_driver=%s\n' "${video_driver}"
    printf 'graphics_backend=%s\n' "${graphics_backend}"
    printf 'sdl_audio_driver=%s\n' "${audio_driver}"
    printf 'source_log_included=%s\n' "$(YesNo "${SOURCE_LOG}")"
  } >"${destination}"
}

WriteMarkerSummary() {
  local source="$1"
  local destination="$2"
  local audio_status=unknown input_status=unknown lifecycle_status=unknown
  local network_integrity_status=not-observed
  local first_present=no jni_on_load=no actual_video_driver=unknown
  local actual_graphics_backend=unknown actual_audio_backend=unknown
  if [[ -s "${source}" ]]; then
    grep -Fq 'first Roblox Vulkan frame presented' "${source}" && first_present=yes || true
    grep -Fq 'JNI_OnLoad' "${source}" && jni_on_load=yes || true
    if grep -Eq '\[sighter\]\[audio\].*(failure|init_failed|write_failed|close_failed)|audio shutdown blocked' "${source}"; then
      audio_status=failed
    elif grep -Eq '\[sighter\]\[audio\].*(shutdown|closed).*pending_buffers=0|OpenSL player shutdown:.*clean=true' "${source}"; then
      audio_status=shutdown-cleanly
    elif grep -Eq '\[sighter\]\[audio\].*(initialized|realized|first_submission)' "${source}"; then
      audio_status=started
    else
      audio_status=not-observed
    fi
    if grep -Fq 'typed production input ready' "${source}"; then
      input_status=ready
    elif grep -Eq '\[input\].*(failed|rejected|terminal)' "${source}"; then
      input_status=failed
    else
      input_status=not-observed
    fi
    if grep -Fq '[main] Roblox lifecycle shutdown: Stopped' "${source}"; then
      lifecycle_status=stopped
    elif grep -Eq '\[lifecycle\].*(failed|error)|lifecycle shutdown.*failed' "${source}"; then
      lifecycle_status=failed
    elif grep -Eq 'setStage:|\[lifecycle\]' "${source}"; then
      lifecycle_status=active-or-incomplete
    else
      lifecycle_status=not-observed
    fi
    if grep -Fq '[network] remote attestation timeout disconnect=319' \
        "${source}"; then
      network_integrity_status=remote-attestation-timeout
    elif grep -Fq '[network] remote attestation rejected' "${source}"; then
      network_integrity_status=remote-attestation-rejected
    fi
    local window_selection audio_selection
    window_selection="$(grep -E '\[window\] graphics backend=[A-Za-z0-9._+-]+ video=[A-Za-z0-9._+-]+' \
      "${source}" | tail -n 1 || true)"
    actual_graphics_backend="$(sed -n 's/.*graphics backend=\([A-Za-z0-9._+-]*\).*/\1/p' \
      <<<"${window_selection}")"
    actual_video_driver="$(sed -n 's/.* video=\([A-Za-z0-9._+-]*\).*/\1/p' \
      <<<"${window_selection}")"
    audio_selection="$(grep -E '\[sighter\]\[audio\] backend=[A-Za-z0-9._+-]+' \
      "${source}" | tail -n 1 || true)"
    actual_audio_backend="$(sed -n 's/.*backend=\([A-Za-z0-9._+-]*\).*/\1/p' \
      <<<"${audio_selection}")"
  fi
  actual_graphics_backend="$(GraphicsBackendToken \
    "${actual_graphics_backend}")"
  actual_video_driver="$(VideoDriverToken "${actual_video_driver}")"
  actual_audio_backend="$(AudioBackendToken "${actual_audio_backend}")"
  {
    printf 'jni_on_load=%s\n' "${jni_on_load}"
    printf 'first_vulkan_present=%s\n' "${first_present}"
    printf 'audio_status=%s\n' "${audio_status}"
    printf 'input_status=%s\n' "${input_status}"
    printf 'lifecycle_status=%s\n' "${lifecycle_status}"
    printf 'network_integrity_status=%s\n' "${network_integrity_status}"
    printf 'actual_graphics_backend=%s\n' "${actual_graphics_backend}"
    printf 'actual_video_driver=%s\n' "${actual_video_driver}"
    printf 'actual_audio_backend=%s\n' "${actual_audio_backend}"
  } >"${destination}"
}

WriteVulkanSummary() {
  local destination="$1"
  local raw="${WORK_ROOT}/vulkaninfo.raw" raw_is_temporary=true
  local fixture="${SIGHTER_SUPPORT_VULKANINFO_FILE:-}" fixture_fd=""
  if [[ -n "${fixture}" ]]; then
    if [[ ! -f "${fixture}" || -L "${fixture}" || ! -r "${fixture}" ]]; then
      printf 'status=unavailable\n' >"${destination}"
      return 0
    fi
    exec {fixture_fd}<"${fixture}" || {
      printf 'status=unavailable\n' >"${destination}"
      return 0
    }
    if [[ "$(stat -Lc '%F' "/proc/self/fd/${fixture_fd}" 2>/dev/null)" != \
          "regular file" ||
          "$(stat -Lc '%s' "/proc/self/fd/${fixture_fd}" 2>/dev/null)" -gt \
          1048576 ]]; then
      printf 'status=unavailable\n' >"${destination}"
      return 0
    fi
    raw="/proc/self/fd/${fixture_fd}"
    raw_is_temporary=false
  else
    # Do not honor an executable override from a failed process. A collector
    # runs beside private work files, so only the fixed, root-owned system tool
    # is allowed and it receives a minimal display/session environment.
    local vulkaninfo=/usr/bin/vulkaninfo
    if [[ ! -f "${vulkaninfo}" || -L "${vulkaninfo}" ||
          ! -x "${vulkaninfo}" ||
          "$(stat -c '%u' -- "${vulkaninfo}" 2>/dev/null)" != 0 ||
          -n "$(/usr/bin/find "${vulkaninfo}" -maxdepth 0 -perm /022 \
            -print -quit 2>/dev/null)" ]]; then
      printf 'status=unavailable\n' >"${destination}"
      return 0
    fi
    local -a clean_environment=(
      PATH=/usr/bin:/bin
      LC_ALL=C
    )
    local name
    for name in DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE; do
      [[ -z "${!name:-}" ]] || clean_environment+=("${name}=${!name}")
    done
    if command -v timeout >/dev/null 2>&1; then
      timeout --signal=TERM --kill-after=1s 5s \
        /usr/bin/env -i "${clean_environment[@]}" \
        "${vulkaninfo}" --summary >"${raw}" 2>/dev/null || true
    else
      /usr/bin/env -i "${clean_environment[@]}" \
        "${vulkaninfo}" --summary >"${raw}" 2>/dev/null || true
    fi
  fi
  {
    printf 'status=available\n'
    awk '
      function first_value(line, value) {
        value = line
        sub(/^.*[:=][[:space:]]*/, "", value)
        sub(/[[:space:]].*$/, "", value)
        return value
      }
      /^[[:space:]]*Vulkan Instance Version[[:space:]]*[:=]/ {
        value = first_value($0)
        if (length(value) <= 32 && value ~ /^[0-9][0-9.]*$/) {
          print "instanceVersion=" value
        }
        next
      }
      /^[[:space:]]*(deviceName|driverName|driverInfo)[[:space:]]*[:=]/ {
        key = $0
        sub(/^[[:space:]]*/, "", key)
        sub(/[[:space:]]*[:=].*$/, "", key)
        print key "=<REDACTED>"
        next
      }
      /^[[:space:]]*deviceType[[:space:]]*[:=]/ {
        value = first_value($0)
        if (value ~ /^(OTHER|INTEGRATED_GPU|DISCRETE_GPU|VIRTUAL_GPU|CPU|PHYSICAL_DEVICE_TYPE_OTHER|PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU|PHYSICAL_DEVICE_TYPE_DISCRETE_GPU|PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU|PHYSICAL_DEVICE_TYPE_CPU|VK_PHYSICAL_DEVICE_TYPE_OTHER|VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU|VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU|VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU|VK_PHYSICAL_DEVICE_TYPE_CPU)$/) {
          print "deviceType=" value
        }
        next
      }
      /^[[:space:]]*(apiVersion|driverVersion)[[:space:]]*[:=]/ {
        key = $0
        sub(/^[[:space:]]*/, "", key)
        sub(/[[:space:]]*[:=].*$/, "", key)
        value = first_value($0)
        if (length(value) <= 32 && value ~ /^[0-9][0-9.]*$/) {
          print key "=" value
        }
        next
      }
      /^[[:space:]]*(vendorID|deviceID)[[:space:]]*[:=]/ {
        key = $0
        sub(/^[[:space:]]*/, "", key)
        sub(/[[:space:]]*[:=].*$/, "", key)
        value = first_value($0)
        if (length(value) <= 18 && value ~ /^(0x)?[0-9A-Fa-f]+$/) {
          print key "=" value
        }
      }
    ' "${raw}" | head -80
  } >"${destination}"
  [[ "${raw_is_temporary}" == false ]] || rm -f -- "${raw}"
}

PruneOldBundles() {
  mapfile -t archives < <(find "${OUTPUT_ROOT}" -maxdepth 1 -type f \
    -name 'sighter-support-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | cut -d' ' -f2-)
  (( ${#archives[@]} > 10#${MAX_BUNDLES} )) || return 0
  local index
  for ((index = ${#archives[@]} - 1; index >= 10#${MAX_BUNDLES}; --index)); do
    rm -f -- "${archives[index]}"
  done
}

Main() {
  ParseArguments "$@"
  command -v tar >/dev/null 2>&1 || Die "tar is required"
  command -v gzip >/dev/null 2>&1 || Die "gzip is required"
  local output_existed=false
  if [[ -e "${OUTPUT_ROOT}" || -L "${OUTPUT_ROOT}" ]]; then
    output_existed=true
    [[ -d "${OUTPUT_ROOT}" && ! -L "${OUTPUT_ROOT}" ]] ||
      Die "output path must be a real directory"
    [[ "$(stat -c '%u' -- "${OUTPUT_ROOT}")" == "$(id -u)" ]] ||
      Die "output directory must be owned by the current user"
  fi
  [[ "${OUTPUT_ROOT}" != / && "${OUTPUT_ROOT}" != "${HOME:-/nonexistent}" &&
     "${OUTPUT_ROOT}" != "${DATA_ROOT}" &&
     "${OUTPUT_ROOT}" != "${CACHE_ROOT}" &&
     "${OUTPUT_ROOT}" != "${STATE_ROOT}" &&
     "${OUTPUT_ROOT}" != "${CONFIG_ROOT}" &&
     "${OUTPUT_ROOT}" != "${AUTH_ROOT}" ]] ||
    Die "output directory must be a dedicated support directory"
  mkdir -p -- "${OUTPUT_ROOT}"
  if [[ "${output_existed}" == false ||
        "${OUTPUT_ROOT}" == "${STATE_ROOT}/support" ]]; then
    chmod 0700 -- "${OUTPUT_ROOT}"
  fi
  WORK_ROOT="$(mktemp -d "${OUTPUT_ROOT}/.support-work.XXXXXX")"
  local content_root="${WORK_ROOT}/sighter-support"
  mkdir -p -- "${content_root}"
  chmod 0700 -- "${content_root}"

  WriteRuntimeSummary "${content_root}/runtime.txt"
  WritePayloadSummary "${content_root}/payload.txt"
  if [[ -n "${SOURCE_LOG}" ]]; then
    SanitizeLog "/proc/self/fd/${SOURCE_LOG_FD}" \
      "${content_root}/recent.log"
  else
    : >"${content_root}/recent.log"
  fi
  WriteMarkerSummary "${content_root}/recent.log" \
    "${content_root}/markers.txt"
  WriteVulkanSummary "${content_root}/vulkan.txt"
  chmod 0600 -- "${content_root}"/*

  local stamp archive suffix
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  ARCHIVE_TEMP="$(mktemp "${OUTPUT_ROOT}/.sighter-support-${stamp}.XXXXXX.tar.gz")"
  suffix="${ARCHIVE_TEMP%.tar.gz}"
  suffix="${suffix##*.}"
  archive="${OUTPUT_ROOT}/sighter-support-${stamp}-${suffix}.tar.gz"
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C \
    /usr/bin/tar -C "${WORK_ROOT}" --format=ustar --owner=0 --group=0 \
    --numeric-owner --mtime=@0 --sort=name --no-acls --no-xattrs \
    --no-selinux -cf - sighter-support | \
    /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C \
      /usr/bin/gzip -n >"${ARCHIVE_TEMP}"
  chmod 0600 -- "${ARCHIVE_TEMP}"
  mv -- "${ARCHIVE_TEMP}" "${archive}"
  ARCHIVE_TEMP=""
  rm -rf -- "${WORK_ROOT}"
  WORK_ROOT=""
  PruneOldBundles
  printf '%s\n' "${archive}"
}

trap Cleanup EXIT
Main "$@"

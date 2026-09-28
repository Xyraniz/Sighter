#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
# Licensed under the Apache License, Version 2.0.

set -Eeuo pipefail

collector_input="${1:?support collector is required}"
smoke_input="${2:?readiness harness is required}"
readonly collector="$(cd -P -- "$(dirname -- "${collector_input}")" && pwd)/$(basename -- "${collector_input}")"
readonly smoke="$(cd -P -- "$(dirname -- "${smoke_input}")" && pwd)/$(basename -- "${smoke_input}")"
readonly temp_dir="$(mktemp -d)"
trap 'rm -rf -- "${temp_dir}"' EXIT

readonly fake_home="${temp_dir}/home/private-user"
readonly data_root="${temp_dir}/data"
readonly cache_root="${temp_dir}/cache"
readonly state_root="${temp_dir}/state"
readonly output_root="${state_root}/support"
mkdir -p -- "${fake_home}" "${data_root}" "${cache_root}" "${state_root}"

readonly build_id=d0cb1fa0deb3d9161b4cd77530cbcd2e50de3a21
jq -n --arg build_id "${build_id}" \
  '{schema_version:1,
    payload_id:("2546-" + $build_id),
    payload_path:("payloads/2546-" + $build_id),
    version_name:"2.725.1142", version_code:2546,
    elf_build_id:$build_id}' >"${data_root}/current.json"

readonly raw_log="${temp_dir}/runtime.log"
printf '%s\n' \
  "[FATAL] Cannot load ${fake_home}/.config/sighter/config.yaml" \
  '[runtime] cookie=.ROBLOSECURITY=super-secret-cookie' \
  '[runtime] authorization=Bearer super-secret-token' \
  '[runtime] request https://example.invalid/private?ticket=join-secret' \
  '[runtime] player=Savva phone=555-1234 city=Moscow' \
  '[window] graphics backend=Savva video=Alice egl=system gles=system' \
  '[sighter][audio] backend=Bob' \
  '[window] caption=Alice-Laptop' \
  '[window] initialized title=Savva private window width=1280' \
  '[audio-menu] device 0: Savva Bluetooth Headset' \
  '[sighter][audio] selected output=Savva Bluetooth Headset' \
  '[FATAL] account mail user@example.test from 192.0.2.44 id 123456789 UUID 123e4567-e89b-12d3-a456-426614174000' \
  '[window] graphics backend=direct-vulkan video=x11 egl=system gles=system' \
  '[vulkan] Android WSI -> SDL3 host adapter ready' \
  '[window] first Roblox Vulkan frame presented' \
  '[input] typed production input ready: mouse=1 touch=1 keyboard=1' \
  '[sighter][audio] fmod_java initialized channels=2 sample_rate_hz=48000 block_size_frames=512 block_count=4' \
  '[sighter][audio] OpenSL player shutdown: submitted=8 consumed=8 clean=true' \
  'setStage: (stage:UGCGame)' \
  '[I/Roblox] [DFLog::NetworkClient] Disconnect reason received: 319' \
  '[I/Roblox] Roblox was not able to verify the integrity of the game due to a network issue. Please reconnect.' \
  '[main] Roblox lifecycle shutdown: Stopped' \
  >"${raw_log}"

readonly fake_vulkaninfo_output="${temp_dir}/vulkaninfo.txt"
printf '%s\n' \
  'Vulkan Instance Version: 1.3.280' \
  'deviceName = Alice-PC GPU' \
  'deviceType = DISCRETE_GPU' \
  'apiVersion = 1.3.280' \
  'driverVersion = 550.78' \
  'vendorID = 0x10de' \
  'deviceID = 0x2684' \
  'driverName = savva@example.test' \
  'driverInfo = built by Savva in /home/private-user/driver' \
  'ignoredPrivatePath = /home/private-user/secret' \
  >"${fake_vulkaninfo_output}"

# An executable override from a failed process must never run beside the
# collector work directory. Vulkan parser tests use a bounded read-only file.
readonly hostile_vulkaninfo="${temp_dir}/hostile-vulkaninfo"
readonly hostile_marker="${temp_dir}/hostile-vulkaninfo-ran"
printf '%s\n' '#!/usr/bin/env bash' "touch '${hostile_marker}'" \
  >"${hostile_vulkaninfo}"
chmod 0700 -- "${hostile_vulkaninfo}"

archive="$(
  HOME="${fake_home}" \
  SIGHTER_DATA_ROOT="${data_root}" \
  SIGHTER_CACHE_ROOT="${cache_root}" \
  SIGHTER_STATE_ROOT="${state_root}" \
  SIGHTER_SUPPORT_OUTPUT_ROOT="${output_root}" \
  SIGHTER_SUPPORT_VULKANINFO="${hostile_vulkaninfo}" \
  SIGHTER_SUPPORT_VULKANINFO_FILE="${fake_vulkaninfo_output}" \
  XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY=wayland-test DISPLAY=:99 \
  SDL_VIDEODRIVER=x11 SIGHTER_GRAPHICS_BACKEND=direct-vulkan \
    "${collector}" --context readiness --reason tier-C-failed \
      --exit-code 42 --log "${raw_log}"
)"
[[ ! -e "${hostile_marker}" ]] || {
  echo 'support collector executed an untrusted vulkaninfo override' >&2
  exit 1
}

[[ "${archive}" == "${output_root}"/sighter-support-*.tar.gz ]]
[[ -f "${archive}" && ! -L "${archive}" ]]
[[ "$(stat -c '%a' "${output_root}")" == 700 ]]
[[ "$(stat -c '%a' "${archive}")" == 600 ]]

readonly extracted="${temp_dir}/extracted"
mkdir -p -- "${extracted}"
tar -C "${extracted}" -xzf "${archive}"
readonly bundle="${extracted}/sighter-support"
[[ "$(find "${bundle}" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)" == \
  $'markers.txt\npayload.txt\nrecent.log\nruntime.txt\nvulkan.txt' ]]

grep -Fxq 'context=readiness' "${bundle}/runtime.txt"
grep -Fxq 'reason=tier-C-failed' "${bundle}/runtime.txt"
grep -Fxq 'exit_code=42' "${bundle}/runtime.txt"
grep -Fxq 'sdl_video_driver=x11' "${bundle}/runtime.txt"
grep -Fxq 'graphics_backend=direct-vulkan' "${bundle}/runtime.txt"
grep -Fxq 'status=active' "${bundle}/payload.txt"
grep -Fxq 'version_code=2546' "${bundle}/payload.txt"
grep -Fxq "elf_build_id=${build_id}" "${bundle}/payload.txt"
grep -Fxq 'first_vulkan_present=yes' "${bundle}/markers.txt"
grep -Fxq 'audio_status=shutdown-cleanly' "${bundle}/markers.txt"
grep -Fxq 'input_status=ready' "${bundle}/markers.txt"
grep -Fxq 'lifecycle_status=stopped' "${bundle}/markers.txt"
grep -Fxq 'network_integrity_status=remote-attestation-timeout' \
  "${bundle}/markers.txt"
grep -Fxq 'actual_graphics_backend=direct-vulkan' "${bundle}/markers.txt"
grep -Fxq 'actual_video_driver=x11' "${bundle}/markers.txt"
grep -Fxq 'deviceName=<REDACTED>' "${bundle}/vulkan.txt"
grep -Fxq 'driverName=<REDACTED>' "${bundle}/vulkan.txt"
grep -Fxq 'driverInfo=<REDACTED>' "${bundle}/vulkan.txt"
grep -Fxq 'vendorID=0x10de' "${bundle}/vulkan.txt"
grep -Fxq 'deviceID=0x2684' "${bundle}/vulkan.txt"
grep -Fxq 'driverVersion=550.78' "${bundle}/vulkan.txt"
grep -Fq '[FATAL] payload load failure' "${bundle}/recent.log"
grep -Fxq '[network] remote attestation timeout disconnect=319' \
  "${bundle}/recent.log"
grep -Fxq '[network] remote attestation rejected' "${bundle}/recent.log"

if grep -R -E 'private-user|super-secret|ROBLOSECURITY|authorization=|https://|ignoredPrivatePath|user@example|192\.0\.2\.44|123456789|123e4567|Savva|Alice|Bob|Carol|Bluetooth Headset|555-1234|Moscow' \
    "${bundle}"; then
  echo 'support archive leaked private runtime data' >&2
  exit 1
fi
if tar -tvzf "${archive}" | grep -Eq "$(id -un)|$(id -gn)"; then
  echo 'support archive leaked local owner names in tar metadata' >&2
  exit 1
fi
if gzip -dc "${archive}" | strings | grep -Fq "$(id -un)"; then
  echo 'support archive leaked the local user name' >&2
  exit 1
fi

# A candidate-aware updater bundle must identify the canary payload instead
# of the still-active baseline.
readonly candidate_id=1686400865ae0e408cd7bd67de7a439625c6fd13
readonly candidate_metadata="${temp_dir}/candidate.json"
jq -n --arg build_id "${candidate_id}" \
  '{schema_version:1,version_name:"2.727.1199",version_code:2628,
    elf_build_id:$build_id}' >"${candidate_metadata}"
candidate_archive="$(
  HOME="${fake_home}" SIGHTER_DATA_ROOT="${data_root}" \
  SIGHTER_CACHE_ROOT="${cache_root}" SIGHTER_STATE_ROOT="${state_root}" \
    "${collector}" --context updater --reason canary-failed --exit-code 139 \
      --payload-metadata "${candidate_metadata}" --log "${raw_log}"
)"
rm -rf -- "${extracted}"
mkdir -p -- "${extracted}"
tar -C "${extracted}" -xzf "${candidate_archive}"
grep -Fxq 'status=candidate' "${bundle}/payload.txt"
grep -Fxq 'version_code=2628' "${bundle}/payload.txt"
grep -Fxq "elf_build_id=${candidate_id}" "${bundle}/payload.txt"

# Free-form environment labels are not diagnostics enums and must collapse to
# unknown instead of becoming an accidental user-name channel.
label_archive="$(
  HOME="${fake_home}" SIGHTER_DATA_ROOT="${data_root}" \
  SIGHTER_CACHE_ROOT="${cache_root}" SIGHTER_STATE_ROOT="${state_root}" \
  XDG_SESSION_TYPE=Carol SDL_VIDEODRIVER=Alice \
  SIGHTER_GRAPHICS_BACKEND=Savva SDL_AUDIODRIVER=Bob \
    "${collector}" --context manual --reason enum-redaction --exit-code 1
)"
rm -rf -- "${extracted}"
mkdir -p -- "${extracted}"
tar -C "${extracted}" -xzf "${label_archive}"
grep -Fxq 'session_type=unknown' "${bundle}/runtime.txt"
grep -Fxq 'sdl_video_driver=unknown' "${bundle}/runtime.txt"
grep -Fxq 'graphics_backend=unknown' "${bundle}/runtime.txt"
grep -Fxq 'sdl_audio_driver=unknown' "${bundle}/runtime.txt"
if grep -R -E 'Alice|Bob|Carol|Savva' "${bundle}"; then
  echo 'support archive retained a free-form backend label' >&2
  exit 1
fi

# A blocked SDL teardown is an audio failure even without an audio-tagged
# queue line.
readonly blocked_audio_log="${temp_dir}/blocked-audio.log"
printf '%s\n' '[main] audio shutdown blocked SDL teardown' \
  >"${blocked_audio_log}"
blocked_archive="$(
  HOME="${fake_home}" SIGHTER_DATA_ROOT="${data_root}" \
  SIGHTER_CACHE_ROOT="${cache_root}" SIGHTER_STATE_ROOT="${state_root}" \
    "${collector}" --context manual --reason audio-shutdown-blocked \
      --exit-code 1 --log "${blocked_audio_log}"
)"
rm -rf -- "${extracted}"
mkdir -p -- "${extracted}"
tar -C "${extracted}" -xzf "${blocked_archive}"
grep -Fxq 'audio_status=failed' "${bundle}/markers.txt"

# Tool-control variables must not alter the archive or execute tar hooks.
readonly hook_marker="${temp_dir}/tar-hook-ran"
TAR_OPTIONS="--checkpoint=1 --checkpoint-action=exec=touch\\ ${hook_marker}" \
  HOME="${fake_home}" SIGHTER_DATA_ROOT="${data_root}" \
  SIGHTER_STATE_ROOT="${state_root}" \
  "${collector}" --context manual --reason hostile-environment \
    --exit-code 1 >/dev/null
[[ ! -e "${hook_marker}" ]] || {
  echo 'support collector honored hostile TAR_OPTIONS' >&2
  exit 1
}
if find "${bundle}" -type l -print -quit | grep -q .; then
  echo 'support archive contains a symlink' >&2
  exit 1
fi

ln -s -- "${raw_log}" "${temp_dir}/runtime-link.log"
if HOME="${fake_home}" SIGHTER_DATA_ROOT="${data_root}" \
    SIGHTER_STATE_ROOT="${state_root}" \
    "${collector}" --context manual --reason unsafe-log --exit-code 1 \
      --log "${temp_dir}/runtime-link.log" >/dev/null 2>&1; then
  echo 'support collector accepted a symlink log' >&2
  exit 1
fi

# The readiness harness owns the raw log and must create exactly one bundle
# after a binary failure without replacing that failure status.
readonly fake_binary="${temp_dir}/sighter"
printf '%s\n' '#!/usr/bin/env bash' 'echo "[FATAL] fake runtime failure" >&2' \
  'exit 42' >"${fake_binary}"
chmod 0700 -- "${fake_binary}"
rm -f -- "${output_root}"/sighter-support-*.tar.gz
set +e
smoke_output="$(
  HOME="${fake_home}" SIGHTER_DATA_ROOT="${data_root}" \
  SIGHTER_CACHE_ROOT="${cache_root}" SIGHTER_STATE_ROOT="${state_root}" \
  SIGHTER_SUPPORT_OUTPUT_ROOT="${output_root}" \
  SIGHTER_SUPPORT_BUNDLE_SCRIPT="${collector}" \
  SIGHTER_WORKING_DIRECTORY="${temp_dir}" \
  SIGHTER_LOG_DIR="${temp_dir}/readiness-logs" \
  SIGHTER_BIN="${fake_binary}" SDL_VIDEODRIVER=dummy \
    "${smoke}" A 2>&1
)"
smoke_status=$?
set -e
[[ "${smoke_status}" -eq 42 ]]
grep -Fq 'support_bundle=' <<<"${smoke_output}"
[[ "$(find "${output_root}" -maxdepth 1 -type f \
  -name 'sighter-support-*.tar.gz' | wc -l)" -eq 1 ]]

printf 'support bundle privacy and readiness integration passed\n'

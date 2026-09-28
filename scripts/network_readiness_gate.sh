#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# Validates an authenticated public-place readiness log. Marker matches can
# contain account, game, ticket, server, or address data, so this script never
# prints matching lines or caller-provided values.

set -euo pipefail

if [[ "$#" -ne 3 || "$1" != "validate" ]]; then
  echo "usage: $0 validate EXPECTED_PLACE_ID PRIVATE_NETWORK_LOG" >&2
  exit 2
fi

EXPECTED_PLACE_ID="$2"
LOG="$3"
if [[ ! "${EXPECTED_PLACE_ID}" =~ ^[1-9][0-9]{0,18}$ ]] ||
   { [[ "${#EXPECTED_PLACE_ID}" -eq 19 ]] &&
     [[ "${EXPECTED_PLACE_ID}" > "9223372036854775807" ]]; }; then
  echo "NETWORK readiness requires a positive signed 64-bit expected place" >&2
  exit 2
fi
if [[ ! -f "${LOG}" || -L "${LOG}" || ! -r "${LOG}" ]]; then
  echo "NETWORK readiness requires a private regular log" >&2
  exit 2
fi
network_log_mode="$(stat -c '%a' -- "${LOG}" 2>/dev/null || true)"
if [[ "${network_log_mode}" != "600" ]]; then
  echo "NETWORK readiness raw log must have mode 0600" >&2
  exit 1
fi

network_failed=0
network_previous_line=0

NetworkRequireFixed() {
  local label="$1"
  local marker="$2"
  if ! rg --fixed-strings --quiet -- "${marker}" "${LOG}"; then
    echo "NETWORK readiness marker missing: ${label}" >&2
    network_failed=1
  fi
}

NetworkRequireRegex() {
  local label="$1"
  local marker="$2"
  if ! rg --quiet -- "${marker}" "${LOG}"; then
    echo "NETWORK readiness marker missing: ${label}" >&2
    network_failed=1
  fi
}

NetworkOrderedFixed() {
  local label="$1"
  local marker="$2"
  local marker_line
  marker_line="$(
    rg --fixed-strings --line-number -- "${marker}" "${LOG}" \
      | awk -F: -v previous="${network_previous_line}" \
          '$1 > previous && !found { print $1; found = 1 }' \
      || true
  )"
  if [[ -z "${marker_line}" ]]; then
    echo "NETWORK readiness order violation: ${label}" >&2
    network_failed=1
    return
  fi
  network_previous_line="${marker_line}"
}

NetworkOrderedRegex() {
  local label="$1"
  local marker="$2"
  local marker_line
  marker_line="$(
    rg --line-number -- "${marker}" "${LOG}" \
      | awk -F: -v previous="${network_previous_line}" \
          '$1 > previous && !found { print $1; found = 1 }' \
      || true
  )"
  if [[ -z "${marker_line}" ]]; then
    echo "NETWORK readiness order violation: ${label}" >&2
    network_failed=1
    return
  fi
  network_previous_line="${marker_line}"
}

NetworkForbidRegex() {
  local label="$1"
  local marker="$2"
  if rg --ignore-case --quiet -- "${marker}" "${LOG}"; then
    echo "NETWORK readiness forbidden marker detected: ${label}" >&2
    network_failed=1
  fi
}

NetworkRequireRegex \
  "supported exact Build-ID profile" \
  '^[[:space:]]+\[compat\] Roblox [^[:space:]]+ Build ID [0-9a-f]{40} \(supported\)$'
NetworkRequireFixed \
  "legacy binary patches disabled" \
  "[compat] legacy binary patches: disabled"
NetworkRequireFixed \
  "signal recovery disabled" \
  "[compat] signal-recovery handler disabled"
NetworkRequireFixed \
  "native allocator retained" \
  "[compat] native allocator retained; host allocator bridges disabled"

NetworkForbidRegex \
  "guest or rejected typed authentication" \
  '\[auth\] explicit guest identity selected|Typed Roblox authentication preflight failed|authentication rejected|authentication service unavailable'
NetworkForbidRegex \
  "legacy crash recovery" \
  '^[[:space:]]*\[patch\]|recovered from (crash|SIG)|startup path cannot continue'
NetworkForbidRegex \
  "fatal process failure" \
  '\[FATAL\]|Segmentation fault|core dumped'
NetworkForbidRegex \
  "synthetic game-loaded event" \
  'nativeAppBridgeV2SendAppEventOnGameLoaded'
NetworkForbidRegex \
  "invalid initial game resume" \
  'nativeAppBridgeV2ResumeGameWithPlatformParams after StartGame'
NetworkForbidRegex \
  "credential material in log" \
  '\.ROBLOSECURITY|_\|WARNING:-DO-NOT-SHARE-THIS|Authorization:[[:space:]]*Bearer|authenticationTicket'
NetworkForbidRegex \
  "remote attestation timeout (disconnect 319)" \
  'Disconnect reason received:[[:space:]]*319([^0-9]|$)|Disconnection Notification\.[[:space:]]*Reason:[[:space:]]*319([^0-9]|$)'
NetworkForbidRegex \
  "remote attestation integrity rejection" \
  'Roblox was not able to verify the integrity of the game|This place (has enabled additional hardware security requirements|requires a trusted operating system)'

NetworkOrderedFixed \
  "typed authenticated identity" \
  "[auth] typed Roblox identity resolved for production VM"
NetworkOrderedRegex \
  "StartGame dispatch" \
  '^[[:space:]]+\[engine\] nativeAppBridgeV2StartGameWithParam$'
NetworkOrderedFixed "UGCGame stage" "setStage: (stage:UGCGame)"
network_ugc_game_line="${network_previous_line}"
NetworkOrderedFixed \
  "typed game lifecycle running" \
  "[game-session] typed lifecycle startup completed: Running"
NetworkOrderedRegex \
  "public-place join dispatch" \
  "\\[FLog::Output\\] ! Joining game '[^']+' place ${EXPECTED_PLACE_ID} at [^[:space:]]+"
NetworkOrderedRegex \
  "accepted server connection" \
  '\[DFLog::NetworkClient\] Connection accepted from [^[:space:]]+'
NetworkOrderedRegex \
  "player replicator created" \
  '\[FLog::Network\] Replicator created for player [^[:space:]]+'
NetworkOrderedRegex \
  "replication schema initialized" \
  '\[FLog::Network\] Time taken to initialize schema = [0-9]+(\.[0-9]+)? ms'
NetworkOrderedRegex \
  "real game-loaded callback" \
  "\\[D/rbx\\.jni\\] onGameLoaded\\(\\) SessionReporterState_GameLoaded placeId:${EXPECTED_PLACE_ID}([^0-9]|$)"
network_game_loaded_line="${network_previous_line}"

# Graphics and network startup run concurrently after UGCGame. A first frame
# may be presented while the server connection is still being accepted, so do
# not impose a false ordering between the two branches. Both branches must
# complete before teardown starts.
network_previous_line="${network_ugc_game_line}"
NetworkOrderedFixed \
  "first real Vulkan frame" \
  "[window] first Roblox Vulkan frame presented"
NetworkOrderedRegex \
  "Vulkan queue present" \
  '^[[:space:]]+\[window\] vkQueuePresentKHR #[1-9][0-9]* '
network_vulkan_present_line="${network_previous_line}"

network_previous_line="${network_game_loaded_line}"
if ((network_vulkan_present_line > network_previous_line)); then
  network_previous_line="${network_vulkan_present_line}"
fi
NetworkOrderedFixed "RenderView destroyed" "RenderView destroyed"
NetworkOrderedFixed \
  "Vulkan pipeline cache saved" \
  "Vulkan: Saved pipeline cache"
NetworkOrderedFixed \
  "SDL WSI adapter stopped" \
  "[vulkan] SDL WSI adapter shut down"
NetworkOrderedFixed \
  "controlled network disconnect" \
  "[DFLog::NetworkClient] Client:Disconnect"
NetworkOrderedFixed \
  "replication disconnect completed" \
  "Time to disconnect replication data:"
NetworkOrderedFixed "NetworkClient removed" "NetworkClient:Remove"
NetworkOrderedFixed \
  "MegaReplicator destroyed" \
  "Destroying MegaReplicator."
NetworkOrderedFixed \
  "UGC controller finalized" \
  "UgcExperienceController: finalized"
NetworkOrderedFixed "Replicator destroyed" "Replicator destroyed:"
NetworkOrderedFixed "stage cleared" "setStage: (stage:None)"
NetworkOrderedFixed \
  "lifecycle stopped" \
  "[main] Roblox lifecycle shutdown: Stopped"

early_update_line="$(
  rg --fixed-strings --line-number \
    "nativeAppBridgeV2UpdateSurfaceGameWithPlatformParams" "${LOG}" \
    | awk -F: -v ugc="${network_ugc_game_line:-0}" \
        '$1 < ugc && !found { print $1; found = 1 }' \
    || true
)"
if [[ -n "${early_update_line}" ]]; then
  echo "NETWORK readiness updated the game surface before UGCGame" >&2
  network_failed=1
fi

if [[ -n "${network_game_loaded_line:-}" ]]; then
  terminal_join_failure_line="$(
    rg --ignore-case --line-number -- \
      'ClientJoinFail|Error processing ticket|Lost connection to the game server|Error_ConnectionAttemptFailed|JoinGamePlaceLauncher-FailureStatus|UgcExperienceController:.*failed to parse' \
      "${LOG}" \
      | awk -F: -v loaded="${network_game_loaded_line}" \
          '$1 < loaded && !found { print $1; found = 1 }' \
      || true
  )"
  if [[ -n "${terminal_join_failure_line}" ]]; then
    echo "NETWORK readiness observed a terminal join failure before game load" >&2
    network_failed=1
  fi
fi

if [[ "${network_failed}" -ne 0 ]]; then
  exit 1
fi

echo "NETWORK readiness passed: authenticated join, replication, Vulkan present, and clean shutdown"

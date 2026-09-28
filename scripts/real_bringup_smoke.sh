#!/usr/bin/env bash
# Progressive real-startup harness for Sighter.
# Tiers A, B, and LEGACY are diagnostic modes. Tier C verifies the
# supported LuaApp graphics path. GAME verifies the local UGCGame graphics
# path. INPUT adds a real SDL-to-JNI click to that gate. NETWORK verifies an
# authenticated public-place join without exposing
# its credential, identifiers, ticket, server address, or raw native log.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKING_DIRECTORY="${SIGHTER_WORKING_DIRECTORY:-${ROOT}}"
[[ -d "${WORKING_DIRECTORY}" ]] || {
  echo "missing runtime working directory: ${WORKING_DIRECTORY}" >&2
  exit 2
}
cd "${WORKING_DIRECTORY}"

BIN="${SIGHTER_BIN:-${ROOT}/build/sighter}"
TIER="${1:-A}"
if (( $# > 0 )); then
  shift
fi
USER_ARGUMENTS=("$@")

ValidateHostAbiProbationBoundary() {
  local allow_unverified=false argument
  for argument in "${USER_ARGUMENTS[@]}"; do
    [[ "${argument}" != --allow-unverified-build ]] ||
      allow_unverified=true
  done
  if [[ "${SIGHTER_HOST_ABI_CANARY:-0}" == 1 ]]; then
    [[ "${SIGHTER_ISOLATED_CANARY:-0}" == 1 &&
       "${SIGHTER_ALLOW_CANDIDATE_HOST_ABI:-0}" == 1 &&
       "${allow_unverified}" == true ]] || {
      echo "candidate host-ABI profile requires isolated probation" >&2
      return 2
    }
    [[ -z "${SIGHTER_HOST_ABI_APPROVAL_RECEIPT:-}" ]] || {
      echo "probation must not reuse an approval receipt" >&2
      return 2
    }
    local probation_artifact
    for probation_artifact in \
        "${SIGHTER_HOST_ABI_PROFILE_FILE:-}" \
        "${SIGHTER_COMPATIBILITY_MANIFEST:-}"; do
      [[ "${probation_artifact}" == /* &&
         -f "${probation_artifact}" &&
         ! -L "${probation_artifact}" ]] || {
        echo "probation host-ABI artifact is not a regular absolute path" >&2
        return 2
      }
    done
    return 0
  fi
  if [[ "${SIGHTER_ALLOW_CANDIDATE_HOST_ABI:-0}" == 1 ]]; then
    echo "candidate host-ABI permission is valid only inside probation" >&2
    return 2
  fi
}

ValidateHostAbiProbationBoundary
LOG_DIR="${SIGHTER_LOG_DIR:-${ROOT}/logs/real_bringup}"
mkdir -p "${LOG_DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ "${TIER}" == "NETWORK" ]]; then
  LOG="$(mktemp "${LOG_DIR}/tierNETWORK_${STAMP}_XXXXXX.log")"
else
  LOG="${LOG_DIR}/tier${TIER}_${STAMP}.log"
fi

if [[ ! -x "${BIN}" ]]; then
  echo "missing binary: ${BIN}" >&2
  exit 2
fi

PrepareActiveAssetLink() {
  local data_root current_manifest payload_path assets_root rbx_root
  data_root="${SIGHTER_DATA_ROOT:-${XDG_DATA_HOME:-${HOME}/.local/share}/sighter}"
  current_manifest="${data_root}/current.json"
  [[ -f "${current_manifest}" && ! -L "${current_manifest}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  payload_path="$(jq -er '.payload_path | select(test("^payloads/[A-Za-z0-9._-]+$"))' \
    "${current_manifest}" 2>/dev/null || true)"
  [[ -n "${payload_path}" ]] || return 0
  assets_root="${data_root}/${payload_path}/assets"
  [[ -d "${assets_root}" && ! -L "${assets_root}" ]] || return 0
  rbx_root="${WORKING_DIRECTORY}/rbx_bin"
  if [[ -e "${rbx_root}" && ! -d "${rbx_root}" ]]; then
    echo "invalid runtime asset-link parent: ${rbx_root}" >&2
    return 1
  fi
  mkdir -p -- "${rbx_root}"
  if [[ -d "${rbx_root}/assets" && ! -L "${rbx_root}/assets" ]]; then
    return 0
  fi
  ln -sfn -- "${assets_root}" "${rbx_root}/assets"
}

case "${TIER}" in
  C|GAME|INPUT|RESIZE|NETWORK)
    if [[ "${SIGHTER_SKIP_UPDATE_CHECK:-0}" != 1 ]]; then
      "${ROOT}/scripts/auto_update_roblox.sh" --skip-build --no-launch
      export SIGHTER_SKIP_UPDATE_CHECK=1
    fi
    PrepareActiveAssetLink
    ;;
esac

export SIGHTER_VALIDATE_ROBLOX_COOKIE="${SIGHTER_VALIDATE_ROBLOX_COOKIE:-0}"
if [[ "${SIGHTER_ISOLATED_CANARY:-0}" == 1 ]]; then
  # Automatic probation must never copy or depend on the user's Roblox
  # credentials. The LuaApp guest path is enough to prove native startup,
  # rendering, and controlled lifecycle/audio shutdown.
  unset SIGHTER_COOKIE_FILE SIGHTER_ROBLOX_COOKIES
  export SIGHTER_ALLOW_NO_COOKIE_LUA_APP=1
fi
export SIGHTER_ENGINE_DETACH="${SIGHTER_ENGINE_DETACH:-0}"
export SIGHTER_CALL_REAL_APP_BRIDGE_INIT="${SIGHTER_CALL_REAL_APP_BRIDGE_INIT:-1}"
export SIGHTER_CALL_REAL_APP_BRIDGE_INIT_THREAD="${SIGHTER_CALL_REAL_APP_BRIDGE_INIT_THREAD:-0}"
export SIGHTER_ENGINE_TRACE="${SIGHTER_ENGINE_TRACE:-1}"
export SIGHTER_SKIP_LIBROBLOX_CTORS="${SIGHTER_SKIP_LIBROBLOX_CTORS:-0}"
# The exact Build-ID profile selects Roblox's native mimalloc by default.
# SIGHTER_HOST_ALLOCATOR_BRIDGES=1 remains an explicit research override.
export SIGHTER_HOST_JNI_SINGLETON_SEED="${SIGHTER_HOST_JNI_SINGLETON_SEED:-0}"
export SIGHTER_INIT_CLIENT_SETTINGS="${SIGHTER_INIT_CLIENT_SETTINGS:-1}"

# Roblox 2.725's multithreaded pack loader performs fseek/fread pairs against
# one shared Android FILE. Host stdio cannot make that two-call transaction
# atomic, so use Roblox's supported vendor deny policy for NVIDIA (0x10de =
# 4318) until the loader owns independent positional streams.
DEFAULT_VULKAN_CLIENT_SETTINGS_OVERRIDES='{"FStringGraphicsVulkanShaderMTDenyPattern":"4318:.*"}'

case "${TIER}" in
  A)
    # Load + JNI_OnLoad + GlobalInit + real V2Init only
    export SIGHTER_HEADLESS=1
    export SIGHTER_KEEPALIVE_MS="${SIGHTER_KEEPALIVE_MS:-8000}"
    export SIGHTER_STARTUP_THREAD_TIMEOUT_MS="${SIGHTER_STARTUP_THREAD_TIMEOUT_MS:-60000}"
    export SIGHTER_CALL_REAL_APP_BRIDGE_START=0
    export SIGHTER_STEP_START_APP_WITH_PARAMS=0
    export SIGHTER_START_LUA_APP_DM=0
    export SIGHTER_STEP_START_LUA_APP_DM=0
    export SIGHTER_START_GAME_WITH_PARAM=0
    export SIGHTER_SEND_APP_READY=0
    export SIGHTER_SEND_GAME_LOADED=0
    export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"
    EXTRA=(--allow-unverified-build --headless)
    ;;
  B)
    # + real StartApp
    export SIGHTER_HEADLESS=1
    export SIGHTER_KEEPALIVE_MS="${SIGHTER_KEEPALIVE_MS:-15000}"
    export SIGHTER_STARTUP_THREAD_TIMEOUT_MS="${SIGHTER_STARTUP_THREAD_TIMEOUT_MS:-90000}"
    export SIGHTER_CALL_REAL_APP_BRIDGE_START=1
    export SIGHTER_STEP_START_APP_WITH_PARAMS=1
    export SIGHTER_START_LUA_APP_DM=0
    export SIGHTER_STEP_START_LUA_APP_DM=0
    export SIGHTER_START_GAME_WITH_PARAM=0
    export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"
    EXTRA=(--allow-unverified-build --headless)
    ;;
  C)
    # Minimal real-window LuaApp path through Roblox's native Vulkan backend.
    # Keep the game surface out until the first app frame is proven.
    export SIGHTER_HEADLESS=0
    export SIGHTER_STARTUP_THREAD_TIMEOUT_MS="${SIGHTER_STARTUP_THREAD_TIMEOUT_MS:-120000}"
    export SIGHTER_CALL_REAL_APP_BRIDGE_START=1
    export SIGHTER_STEP_START_APP_WITH_PARAMS=1
    export SIGHTER_UPDATE_SURFACE_APP_AFTER_START_APP=1
    export SIGHTER_CALL_REAL_APP_BRIDGE_UPDATE_SURFACE=1
    export SIGHTER_START_LUA_APP_DM="${SIGHTER_START_LUA_APP_DM:-1}"
    export SIGHTER_STEP_START_LUA_APP_DM="${SIGHTER_STEP_START_LUA_APP_DM:-1}"
    export SIGHTER_POST_CLIENT_SETTINGS="${SIGHTER_POST_CLIENT_SETTINGS:-1}"
    export SIGHTER_STEP_POST_CLIENT_SETTINGS="${SIGHTER_STEP_POST_CLIENT_SETTINGS:-1}"
    export SIGHTER_FETCH_CLIENT_SETTINGS="${SIGHTER_FETCH_CLIENT_SETTINGS:-1}"
    # ActivityNativeMain.loadDataModel starts LuaApp after V2Init; the surface
    # callback starts AppBridge only afterwards. Preserve that APK ordering.
    export SIGHTER_START_LUA_APP_DM_AFTER_START_APP="${SIGHTER_START_LUA_APP_DM_AFTER_START_APP:-0}"
    export SIGHTER_START_LUA_APP_DM_INLINE="${SIGHTER_START_LUA_APP_DM_INLINE:-1}"
    export SIGHTER_START_LUA_APP_DM_DELAY_MS="${SIGHTER_START_LUA_APP_DM_DELAY_MS:-0}"
    export SIGHTER_START_GAME_WITH_PARAM=0
    export SIGHTER_RESUME_GAME_WITH_PLATFORM_PARAMS_AFTER_START_GAME=0
    export SIGHTER_SEND_APP_READY=0
    export SIGHTER_SEND_GAME_LOADED=0
    export SIGHTER_MAIN_THREAD_MESSAGE_PUMP=1
    export SIGHTER_GRAPHICS_BACKEND="${SIGHTER_GRAPHICS_BACKEND:-direct-vulkan}"
    export SIGHTER_PRELOAD_VULKAN_SHIM=1
    # Do not force the broken GLES UBO translator. Roblox selects its native
    # Vulkan renderer after the adapter advertises VK_KHR_android_surface.
    export SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON="${SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON:-${DEFAULT_VULKAN_CLIENT_SETTINGS_OVERRIDES}}"
    export SIGHTER_REQUIRE_REAL_GRAPHICS=1
    # The gate consumes the present serial from this trace; do not allow a
    # caller override to silently remove its primary graphics evidence.
    export SIGHTER_WINDOW_TRACE=1
    export SIGHTER_EGL_TRACE="${SIGHTER_EGL_TRACE:-1}"
    # Keep the smoke deterministic: retain the first real frame long enough to
    # observe it, then exercise Roblox lifecycle teardown before SDL shutdown.
    export SIGHTER_AUTO_EXIT_AFTER_PRESENT_MS="${SIGHTER_AUTO_EXIT_AFTER_PRESENT_MS:-3000}"
    # Tier C is the supported readiness path for the exact Build ID in the
    # compatibility manifest. It must pass the normal fail-closed gate.
    EXTRA=(--windowed)
    ;;
  GAME|INPUT|RESIZE)
    # Local UGCGame graphics gate after the LuaApp-window tier succeeds.
    # The APK's first valid surface starts the game directly. Update is only
    # for an already-running game, and Resume is only for a paused game.
    export SIGHTER_UPDATE_SURFACE_GAME_BEFORE_START_GAME=0
    export SIGHTER_RESUME_GAME_WITH_PLATFORM_PARAMS_AFTER_START_GAME=0
    export SIGHTER_HEADLESS=0
    export SIGHTER_STARTUP_THREAD_TIMEOUT_MS="${SIGHTER_STARTUP_THREAD_TIMEOUT_MS:-120000}"
    export SIGHTER_CALL_REAL_APP_BRIDGE_START=1
    export SIGHTER_START_LUA_APP_DM=1
    export SIGHTER_START_GAME_WITH_PARAM=1
    # This event belongs to the app-restoration path, not initial StartGame.
    export SIGHTER_SEND_GAME_LOADED=0
    export SIGHTER_FETCH_CLIENT_SETTINGS="${SIGHTER_FETCH_CLIENT_SETTINGS:-1}"
    export SIGHTER_GRAPHICS_BACKEND="${SIGHTER_GRAPHICS_BACKEND:-direct-vulkan}"
    export SIGHTER_PRELOAD_VULKAN_SHIM=1
    export SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON="${SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON:-${DEFAULT_VULKAN_CLIENT_SETTINGS_OVERRIDES}}"
    export SIGHTER_REQUIRE_REAL_GRAPHICS=1
    # The ordered gate consumes vkQueuePresentKHR serials from this trace.
    export SIGHTER_WINDOW_TRACE=1
    export SIGHTER_AUTO_EXIT_AFTER_PRESENT_MS="${SIGHTER_AUTO_EXIT_AFTER_PRESENT_MS:-4000}"
    if [[ "${TIER}" == "INPUT" ]]; then
      export SIGHTER_INPUT_TEST_CLICK=1
    fi
    if [[ "${TIER}" == "RESIZE" ]]; then
      export SIGHTER_RESIZE_READINESS=1
      export SIGHTER_RESIZE_WIDTH="${SIGHTER_RESIZE_WIDTH:-1024}"
      export SIGHTER_RESIZE_HEIGHT="${SIGHTER_RESIZE_HEIGHT:-640}"
    fi
    # GAME uses the same exact Build-ID profile and fail-closed policy as C.
    EXTRA=(--windowed)
    ;;
  NETWORK)
    # Authenticated public-place gate. Unlike GAME, this requires a positive
    # place ID and an authenticated identity. The public-place contract
    # excludes private/reserved/follow-user launch selectors.
    place_id="${SIGHTER_PLACE_ID:-}"
    if [[ ! "${place_id}" =~ ^[1-9][0-9]{0,18}$ ]] ||
       { [[ "${#place_id}" -eq 19 ]] &&
         [[ "${place_id}" > "9223372036854775807" ]]; }; then
      echo "NETWORK requires SIGHTER_PLACE_ID to be a positive signed 64-bit integer" >&2
      exit 2
    fi
    if [[ -n "${SIGHTER_ROBLOX_COOKIES:-}" ]]; then
      echo "NETWORK requires a private cookie file, not a credential in process environment" >&2
      exit 2
    fi
    if [[ -z "${SIGHTER_COOKIE_FILE:-}" ||
          ! -f "${SIGHTER_COOKIE_FILE}" ||
          -L "${SIGHTER_COOKIE_FILE}" ||
          ! -r "${SIGHTER_COOKIE_FILE}" ]]; then
      echo "NETWORK requires a readable private regular cookie file" >&2
      exit 2
    fi
    cookie_mode="$(stat -c '%a' -- "${SIGHTER_COOKIE_FILE}")"
    if (( (8#${cookie_mode: -3} & 8#077) != 0 )); then
      echo "NETWORK cookie file must not be accessible by group or other users" >&2
      exit 2
    fi

    if [[ -n "${SIGHTER_GAME_JOIN_REQUEST_TYPE:-}" &&
          "${SIGHTER_GAME_JOIN_REQUEST_TYPE}" != "0" ]]; then
      echo "NETWORK public-place join requires join request type 0" >&2
      exit 2
    fi
    if [[ -n "${SIGHTER_GAME_JOIN_USER_ID:-}" &&
          "${SIGHTER_GAME_JOIN_USER_ID}" != "0" ]]; then
      echo "NETWORK public-place join requires an empty join target" >&2
      exit 2
    fi
    public_join_excluded_variables=(
      SIGHTER_GAME_ACCESS_CODE
      SIGHTER_GAME_LINK_CODE
      SIGHTER_GAME_RESERVED_SERVER_ACCESS_CODE
      SIGHTER_GAME_CONVERSATION_ID
      SIGHTER_REFERRED_BY_PLAYER_ID
      SIGHTER_GAME_CALL_ID
      SIGHTER_GAME_EVENT_ID
      SIGHTER_GAME_JOIN_ATTEMPT_ID
      SIGHTER_GAME_JOIN_ATTEMPT_ORIGIN
      SIGHTER_GAME_ISO_CONTEXT
      SIGHTER_GAME_ID
      SIGHTER_ROBLOX_USERNAME
      SIGHTER_REFERRAL_PAGE
      SIGHTER_GAME_JOIN_CONTEXT
      SIGHTER_GAME_PARAMS_JSON
    )
    for variable_name in "${public_join_excluded_variables[@]}"; do
      if [[ -n "${!variable_name:-}" ]]; then
        echo "NETWORK public-place join rejects special join selectors" >&2
        exit 2
      fi
    done

    export SIGHTER_ALLOW_NO_COOKIE_LUA_APP=0
    export SIGHTER_GAME_JOIN_REQUEST_TYPE=0
    export SIGHTER_GAME_JOIN_USER_ID=0
    export SIGHTER_UPDATE_SURFACE_GAME_BEFORE_START_GAME=0
    export SIGHTER_RESUME_GAME_WITH_PLATFORM_PARAMS_AFTER_START_GAME=0
    export SIGHTER_HEADLESS=0
    export SIGHTER_STARTUP_THREAD_TIMEOUT_MS="${SIGHTER_STARTUP_THREAD_TIMEOUT_MS:-120000}"
    export SIGHTER_CALL_REAL_APP_BRIDGE_START=1
    export SIGHTER_START_LUA_APP_DM=1
    export SIGHTER_START_GAME_WITH_PARAM=1
    # onGameLoaded must arrive from the real joined DataModel, never from the
    # restoration-only native event used by research paths.
    export SIGHTER_SEND_GAME_LOADED=0
    export SIGHTER_FETCH_CLIENT_SETTINGS="${SIGHTER_FETCH_CLIENT_SETTINGS:-1}"
    export SIGHTER_GRAPHICS_BACKEND="${SIGHTER_GRAPHICS_BACKEND:-direct-vulkan}"
    export SIGHTER_PRELOAD_VULKAN_SHIM=1
    export SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON="${SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON:-${DEFAULT_VULKAN_CLIENT_SETTINGS_OVERRIDES}}"
    export SIGHTER_REQUIRE_REAL_GRAPHICS=1
    export SIGHTER_WINDOW_TRACE=1
    export SIGHTER_AUTO_EXIT_AFTER_PRESENT_MS="${SIGHTER_AUTO_EXIT_AFTER_PRESENT_MS:-20000}"
    if [[ ! "${SIGHTER_AUTO_EXIT_AFTER_PRESENT_MS}" =~ ^[0-9]{1,9}$ ]] ||
       (( 10#${SIGHTER_AUTO_EXIT_AFTER_PRESENT_MS} < 20000 )); then
      echo "NETWORK requires at least 20000 ms after the first present" >&2
      exit 2
    fi
    export SIGHTER_SMOKE_TIMEOUT_S="${SIGHTER_SMOKE_TIMEOUT_S:-120}"
    if [[ ! "${SIGHTER_SMOKE_TIMEOUT_S}" =~ ^[0-9]{1,9}$ ]] ||
       (( 10#${SIGHTER_SMOKE_TIMEOUT_S} < 90 )); then
      echo "NETWORK requires a smoke timeout of at least 90 seconds" >&2
      exit 2
    fi
    # No unverified-build escape hatch: NETWORK is valid only for a supported
    # exact Build-ID profile.
    EXTRA=(--windowed)
    ;;
  LEGACY)
    # Researched 2.721.1108 with offset patches enabled by profile
    OLD="${ROOT}/rbx_bin/versions/2.721.1108-50e1b0abd123350e794226062fe3a1ef360c5f0d/libroblox.so"
    export SIGHTER_HEADLESS=1
    export SIGHTER_KEEPALIVE_MS="${SIGHTER_KEEPALIVE_MS:-20000}"
    export SIGHTER_STARTUP_THREAD_TIMEOUT_MS="${SIGHTER_STARTUP_THREAD_TIMEOUT_MS:-90000}"
    export SIGHTER_CALL_REAL_APP_BRIDGE_INIT=1
    export SIGHTER_CALL_REAL_APP_BRIDGE_START=1
    export SIGHTER_START_LUA_APP_DM=1
    export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"
    EXTRA=(--allow-unverified-build --headless --roblox-lib "${OLD}")
    ;;
  *)
    echo "usage: $0 A|B|C|GAME|INPUT|RESIZE|NETWORK|LEGACY" >&2
    exit 2
    ;;
esac

echo "tier=${TIER} log=${LOG}"
# The outer readiness harness owns the raw log and can produce one useful
# sanitized archive after binary, marker, audio, input, resize, or network
# failure. Suppress the inner normal-launch guard to avoid duplicate bundles.
SUPPORT_BUNDLE_DISABLED="${SIGHTER_DISABLE_SUPPORT_BUNDLE:-0}"
export SIGHTER_DISABLE_SUPPORT_BUNDLE=1
set +e
# Roblox may ignore SIGTERM while a native engine thread is
# active. Bound the smoke run even in that state so the caller gets a
# deterministic result and no stale window/process is left behind. Tier C with
# an explicitly disabled present timer is the supported interactive launch,
# however, and must remain alive until the user closes it.
if [[ "${TIER}" == "NETWORK" ]]; then
  timeout --kill-after=5s "${SIGHTER_SMOKE_TIMEOUT_S}" \
    "${BIN}" "${EXTRA[@]}" "${USER_ARGUMENTS[@]}" >"${LOG}" 2>&1
  rc=$?
  chmod 600 "${LOG}"
elif [[ "${TIER}" == "C" &&
        "${SIGHTER_AUTO_EXIT_AFTER_PRESENT_MS:-}" == "0" ]]; then
  "${BIN}" "${EXTRA[@]}" "${USER_ARGUMENTS[@]}" 2>&1 | tee "${LOG}"
  rc=${PIPESTATUS[0]}
else
  timeout --kill-after=5s "${SIGHTER_SMOKE_TIMEOUT_S:-120}" \
    "${BIN}" "${EXTRA[@]}" "${USER_ARGUMENTS[@]}" 2>&1 | tee "${LOG}"
  rc=${PIPESTATUS[0]}
fi
set -e

if [[ "${TIER}" != "NETWORK" ]]; then
  echo "---- markers ----"
  rg -n 'JNI_OnLoad|nativeGameGlobalInit|nativeAppBridgeV2Init|nativeAppBridgeV2Start|StartLua|Mobile\.rbxl|LuaApp|UGCGame|DeviceGL|RenderJob|Mimalloc|egl(CreateWindowSurface|MakeCurrent|SwapBuffers)|vkQueuePresentKHR|presented|typed production input|SDL readiness pointer|mouse button reached|touch event reached|lifecycle shutdown|automatic exit|abort|FATAL|startup|compat|skipping libroblox' "${LOG}" | head -180 || true
fi

if [[ "${TIER}" == "C" && "${rc}" -eq 0 ]]; then
  required_markers=(
    "[compat] legacy binary patches: disabled"
    "[compat] signal-recovery handler disabled"
    "[compat] native allocator retained; host allocator bridges disabled"
    "[window] first Roblox Vulkan frame presented"
    "[vulkan] SDL WSI adapter shut down"
    "[main] Roblox lifecycle shutdown: Stopped"
  )
  for marker in "${required_markers[@]}"; do
    if ! rg --fixed-strings --quiet "${marker}" "${LOG}"; then
      echo "Tier C readiness marker missing: ${marker}" >&2
      rc=1
    fi
  done
  # Roblox may omit the shader-pack summary even after rendering hundreds of
  # frames. A numbered queue present is stable, renderer-level evidence.
  if ! rg --quiet '\[window\] vkQueuePresentKHR #[1-9][0-9]*' "${LOG}"; then
    echo "Tier C readiness marker missing: real Vulkan queue present" >&2
    rc=1
  fi
fi

if [[ "${TIER}" == "C" && "${rc}" -eq 0 &&
      ( "${SIGHTER_FULLSCREEN_READINESS:-0}" == "1" ||
        "${SIGHTER_FULLSCREEN_READINESS:-0}" == "roundtrip" ) ]]; then
  fullscreen_enter_count="$(rg --fixed-strings --count \
    "[fullscreen] SDL transition committed state=fullscreen" "${LOG}" || true)"
  fullscreen_leave_count="$(rg --fixed-strings --count \
    "[fullscreen] SDL transition committed state=windowed" "${LOG}" || true)"
  if [[ "${SIGHTER_FULLSCREEN_READINESS:-0}" == "roundtrip" &&
        ( "${fullscreen_enter_count:-0}" -lt 1 ||
          "${fullscreen_leave_count:-0}" -lt 1 ) ]]; then
    echo "Tier C fullscreen roundtrip did not observe both SDL transitions" >&2
    rc=1
  fi
  fullscreen_line="$(rg --fixed-strings --line-number \
    "[fullscreen] SDL transition committed" "${LOG}" \
    | cut -d: -f1 | tail -n 1 || true)"
  if [[ -z "${fullscreen_line}" ]]; then
    echo "Tier C fullscreen readiness did not observe an SDL transition" >&2
    rc=1
  else
    post_fullscreen_present_line="$(rg --fixed-strings --line-number \
      "[window] vkQueuePresentKHR #" "${LOG}" \
      | cut -d: -f1 \
      | awk -v boundary="${fullscreen_line}" '$1 > boundary { print; exit }' \
      || true)"
    if [[ -z "${post_fullscreen_present_line}" ]]; then
      echo "Tier C fullscreen readiness did not present after F11" >&2
      rc=1
    fi
  fi

  first_out_of_date_line="$(rg --fixed-strings --line-number --max-count 1 \
    "VK_ERROR_OUT_OF_DATE_KHR" "${LOG}" | cut -d: -f1 || true)"
  last_out_of_date_line="$(rg --fixed-strings --line-number \
    "VK_ERROR_OUT_OF_DATE_KHR" "${LOG}" \
    | cut -d: -f1 | tail -n 1 || true)"
  if [[ -n "${first_out_of_date_line}" ]]; then
    recreation_line="$(rg --fixed-strings --line-number \
      "[surface] LuaApp JNI recreated" "${LOG}" \
      | cut -d: -f1 \
      | awk -v boundary="${first_out_of_date_line}" \
          '$1 > boundary { print; exit }' || true)"
    post_error_present_line="$(rg --fixed-strings --line-number \
      "[window] vkQueuePresentKHR #" "${LOG}" \
      | cut -d: -f1 \
      | awk -v boundary="${last_out_of_date_line}" \
          '$1 > boundary { print; exit }' || true)"
    if [[ -z "${recreation_line}" ]]; then
      echo "Tier C fullscreen readiness did not recreate LuaApp surface" >&2
      rc=1
    fi
    if [[ -z "${post_error_present_line}" ]]; then
      echo "Tier C fullscreen readiness did not present after the last Vulkan out-of-date result" >&2
      rc=1
    fi
  fi
fi

if [[ ("${TIER}" == "GAME" || "${TIER}" == "INPUT" ||
       "${TIER}" == "RESIZE") && "${rc}" -eq 0 ]]; then
  required_markers=(
    "[compat] legacy binary patches: disabled"
    "[compat] signal-recovery handler disabled"
    "[compat] native allocator retained; host allocator bridges disabled"
    "setStage: (stage:UGCGame)"
    "[window] first Roblox Vulkan frame presented"
    "RenderView destroyed"
    "Vulkan: Saved pipeline cache"
    "[vulkan] SDL WSI adapter shut down"
    "UgcExperienceController: finalized"
    "setStage: (stage:None)"
    "[main] Roblox lifecycle shutdown: Stopped"
  )
  for marker in "${required_markers[@]}"; do
    if ! rg --fixed-strings --quiet "${marker}" "${LOG}"; then
      echo "${TIER} readiness marker missing: ${marker}" >&2
      rc=1
    fi
  done

  forbidden_markers=(
    "nativeAppBridgeV2ResumeGameWithPlatformParams after StartGame"
    "nativeAppBridgeV2SendAppEventOnGameLoaded"
  )
  for marker in "${forbidden_markers[@]}"; do
    if rg --fixed-strings --quiet "${marker}" "${LOG}"; then
      echo "${TIER} readiness used a forbidden initial-lifecycle call: ${marker}" >&2
      rc=1
    fi
  done

  ugc_game_line="$(rg --fixed-strings --line-number --max-count 1 \
    "setStage: (stage:UGCGame)" "${LOG}" | cut -d: -f1 || true)"
  early_update_line="$(rg --fixed-strings --line-number \
    "nativeAppBridgeV2UpdateSurfaceGameWithPlatformParams" "${LOG}" \
    | cut -d: -f1 \
    | awk -v ugc="${ugc_game_line:-0}" '$1 < ugc { print; exit }' \
    || true)"
  if [[ -n "${early_update_line}" ]]; then
    echo "${TIER} readiness updated the surface before UGCGame was running" >&2
    rc=1
  fi

  previous_line=0
  ordered_markers=(
    "[engine] nativeAppBridgeV2StartGameWithParam"
    "setStage: (stage:UGCGame)"
    "[window] vkQueuePresentKHR #"
    "setStage: (stage:None)"
    "[main] Roblox lifecycle shutdown: Stopped"
  )
  for marker in "${ordered_markers[@]}"; do
    marker_line="$(rg --fixed-strings --line-number "${marker}" "${LOG}" \
      | cut -d: -f1 \
      | awk -v previous="${previous_line}" '$1 > previous { print; exit }' \
      || true)"
    if [[ -z "${marker_line}" ]]; then
      echo "${TIER} readiness order violation at marker: ${marker}" >&2
      rc=1
      break
    fi
    previous_line="${marker_line}"
  done
fi

if [[ "${TIER}" == "INPUT" && "${rc}" -eq 0 ]]; then
  if ! "${ROOT}/scripts/input_readiness_gate.sh" validate "${LOG}"; then
    rc=1
  fi
fi

if [[ "${TIER}" == "RESIZE" && "${rc}" -eq 0 ]]; then
  if ! "${ROOT}/scripts/resize_readiness_gate.sh" validate "${LOG}"; then
    rc=1
  fi
fi

if [[ ("${TIER}" == "C" || "${TIER}" == "GAME" ||
       "${TIER}" == "INPUT" || "${TIER}" == "RESIZE") &&
      "${rc}" -eq 0 ]]; then
  if ! "${ROOT}/scripts/audio_readiness_gate.sh" "${LOG}"; then
    rc=1
  fi
fi

if [[ "${TIER}" == "NETWORK" ]]; then
  if [[ "${rc}" -eq 0 ]]; then
    if ! "${ROOT}/scripts/network_readiness_gate.sh" validate \
      "${place_id}" "${LOG}"; then
      rc=1
    fi
  else
    echo "NETWORK runtime exited before readiness validation" >&2
  fi
fi

echo "exit=${rc}"
if [[ "${rc}" -ne 0 && "${SUPPORT_BUNDLE_DISABLED}" != 1 ]]; then
  support_collector="${SIGHTER_SUPPORT_BUNDLE_SCRIPT:-${ROOT}/scripts/collect_support_bundle.sh}"
  if [[ "${support_collector}" == /* && -f "${support_collector}" &&
        ! -L "${support_collector}" && -x "${support_collector}" ]]; then
    support_archive="$("${support_collector}" --context readiness \
      --reason "tier-${TIER}-failed" --exit-code "${rc}" --log "${LOG}" \
      2>/dev/null || true)"
    if [[ -n "${support_archive}" ]]; then
      echo "support_bundle=${support_archive}"
    else
      echo "support bundle collection failed" >&2
    fi
  fi
fi
exit "${rc}"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SIGHTER_BUILD_DIR:-${ROOT_DIR}/build}"
BINARY="${BUILD_DIR}/sighter"
LIBROBLOX="${ROBLOX_LIB_PATH:-${ROOT_DIR}/rbx_bin/libroblox.so}"
LOG_DIR="${ROOT_DIR}/logs/runtime/matrix-$(date +%Y%m%d-%H%M%S)"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-12}"
TIMEOUT_SIGNAL="${TIMEOUT_SIGNAL:-KILL}"

mkdir -p "${LOG_DIR}"

if [[ ! -x "${BINARY}" ]]; then
  cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Debug
fi

cmake --build "${BUILD_DIR}" -j"$(nproc)"

run_profile() {
  local name="$1"
  shift
  local log="${LOG_DIR}/${name}.log"
  local summary="${LOG_DIR}/${name}.summary"

  echo "[matrix] ${name}" | tee "${summary}"
  set +e
  timeout -s "${TIMEOUT_SIGNAL}" "${TIMEOUT_SECONDS}s" env \
    SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}" \
    ROBLOX_LIB_PATH="${LIBROBLOX}" \
    "$@" \
    "${BINARY}" >"${log}" 2>&1
  local rc=$?
  set -e

  {
    echo "rc=${rc}"
    echo "log=${log}"
    if rg -q "first Roblox frame presented|SwapBuffers #[0-9]+" "${log}"; then
      echo "frame=yes"
    else
      echo "frame=no"
    fi
    if rg -q "Segmentation fault|Aborted|free\\(\\):|\\[crash\\]|SIGABRT" "${log}"; then
      echo "fatal=yes"
    else
      echo "fatal=no"
    fi
    if rg -q "black waiting frame|presented \\(software\\)" "${log}"; then
      echo "fallback_frame=yes"
    else
      echo "fallback_frame=no"
    fi
    rg -n "Stage6 GL helper state-slot|nativeGameGlobalInit returned|nativeAppBridgeV2InitWithParams returned|recovered|first Roblox frame presented|SwapBuffers|free\\(\\):|SIGABRT|\\[crash\\]" "${log}" | tail -20 || true
  } | tee -a "${summary}"
}

run_profile safe-default \
  SIGHTER_WINDOW_TRACE=1

run_profile helper-tls-slot \
  SIGHTER_WINDOW_TRACE=1 \
  SIGHTER_PATCH_STAGE6_GL_HELPER_STATE_SLOT=1

run_profile gameactivity-surface \
  SIGHTER_WINDOW_TRACE=1 \
  SIGHTER_STEP_GAME_ACTIVITY_INIT=1 \
  SIGHTER_STEP_GAME_ACTIVITY_SURFACE=1 \
  SIGHTER_STEP_ACTIVITY_LIFECYCLE=1 \
  SIGHTER_STEP_START_APP_WITH_PARAMS=0 \
  SIGHTER_START_LUA_APP_DM=0 \
  SIGHTER_MAIN_THREAD_MESSAGE_PUMP=1 \
  SIGHTER_MAIN_THREAD_MESSAGE_PUMP_LIMIT=1

run_profile real-workers-bounded \
  SIGHTER_WINDOW_TRACE=1 \
  SIGHTER_EXIT_EMPTY_GL_HELPER_LOOP=1 \
  SIGHTER_STEP_START_APP_WITH_PARAMS=1 \
  SIGHTER_CALL_REAL_APP_BRIDGE_UPDATE_SURFACE=1 \
  SIGHTER_START_LUA_APP_DM=1 \
  SIGHTER_MAIN_THREAD_MESSAGE_PUMP=1 \
  SIGHTER_MAIN_THREAD_MESSAGE_PUMP_LIMIT=1

echo "[matrix] summaries: ${LOG_DIR}"

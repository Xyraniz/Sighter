#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
BINARY="${BUILD_DIR}/sighter"
LIBROBLOX="${ROBLOX_LIB_PATH:-${ROOT_DIR}/rbx_bin/libroblox.so}"
LOG_DIR="${ROOT_DIR}/logs/runtime"
ATTEMPTS="${ATTEMPTS:-50}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-20}"
TIMEOUT_SIGNAL="${TIMEOUT_SIGNAL:-KILL}"
JOBS="${JOBS:-2}"

mkdir -p "${LOG_DIR}"

hex_to_dec() {
  local value="${1#0x}"
  printf '%d' "0x${value}"
}

for ((attempt = 1; attempt <= ATTEMPTS; ++attempt)); do
  log="${LOG_DIR}/attempt-${attempt}.log"
  summary="${LOG_DIR}/attempt-${attempt}.summary"
  : >"${summary}"

  {
    echo "== attempt ${attempt} =="
    echo "time: $(date -Is)"
    echo "libroblox: ${LIBROBLOX}"
    echo "timeout: ${TIMEOUT_SECONDS}s signal=${TIMEOUT_SIGNAL}"
    echo
    echo "== build =="
  } | tee "${log}"

  if ! cmake --build "${BUILD_DIR}" -j"${JOBS}" >>"${log}" 2>&1; then
    echo "[auto] build failed; see ${log}" | tee -a "${summary}"
    tail -80 "${log}"
    exit 1
  fi

  echo "== runtime ==" >>"${log}"
  set +e
  timeout -s "${TIMEOUT_SIGNAL}" "${TIMEOUT_SECONDS}s" env \
    SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}" \
    ROBLOX_LIB_PATH="${LIBROBLOX}" \
    "${BINARY}" >>"${log}" 2>&1
  status=$?
  set -e

  base="$(sed -n 's/.*mcpelauncher_linker_notifylldb .*libroblox\.so \(0x[0-9a-fA-F]\+\).*/\1/p' "${log}" | tail -1)"
  rip="$(sed -n 's/.*RIP=\(0x[0-9a-fA-F]\+\).*/\1/p' "${log}" | tail -1)"
  stage="$(sed -n 's/.*\\[crash\\] stage=\([0-9]\+\).*/\1/p' "${log}" | tail -1)"
  bytes="$(sed -n 's/.*RIP bytes: \(.*\)$/\1/p' "${log}" | tail -1)"

  {
    echo "[auto] status=${status}"
    echo "[auto] log=${log}"
    if [[ -n "${stage}" ]]; then echo "[auto] stage=${stage}"; fi
    if [[ -n "${base}" ]]; then echo "[auto] base=${base}"; fi
    if [[ -n "${rip}" ]]; then echo "[auto] rip=${rip}"; fi
    if [[ -n "${bytes}" ]]; then echo "[auto] bytes=${bytes}"; fi
  } | tee -a "${summary}"

  if rg -q "Initialisation complete\\." "${log}" &&
     ! rg -q "timeout: the monitored command dumped core|Segmentation fault|Aborted" "${log}"; then
    echo "[auto] startup reached event loop without fatal crash; stopping loop" \
      | tee -a "${summary}"
    tail -120 "${log}"
    exit 0
  fi

  if [[ -n "${base}" && -n "${rip}" ]]; then
    base_dec="$(hex_to_dec "${base}")"
    rip_dec="$(hex_to_dec "${rip}")"
    if (( rip_dec >= base_dec )); then
      offset_dec=$((rip_dec - base_dec))
      offset_hex="$(printf '0x%x' "${offset_dec}")"
      start_hex="$(printf '0x%x' $((offset_dec > 64 ? offset_dec - 64 : 0)))"
      stop_hex="$(printf '0x%x' $((offset_dec + 96)))"
      {
        echo "[auto] libroblox_offset=${offset_hex}"
        echo
        echo "== objdump ${start_hex}..${stop_hex} =="
      } | tee -a "${summary}"
      objdump -d --start-address="${start_hex}" --stop-address="${stop_hex}" \
        "${LIBROBLOX}" | tee -a "${summary}" || true
    fi
  fi

  if ! rg -q "\\[crash\\]" "${log}"; then
    echo "[auto] no crash marker found; stopping loop" | tee -a "${summary}"
    tail -120 "${log}"
    exit 0
  fi

  echo "[auto] crash found; summary: ${summary}"
  tail -80 "${summary}"
done

echo "[auto] attempts exhausted (${ATTEMPTS}); last log: ${log}"
exit 1

#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
source "${SCRIPT_DIR}/payload_integrity.sh"
RBX_BIN_DIR="${PROJECT_ROOT}/rbx_bin"
VERSIONS_DIR="${RBX_BIN_DIR}/versions"
METADATA_PATH="${SIGHTER_UPDATE_PAYLOAD_METADATA_PATH:-${PROJECT_ROOT}/config/roblox_payload.json}"
COMPATIBILITY_PATH="${SIGHTER_UPDATE_COMPATIBILITY_PATH:-${PROJECT_ROOT}/config/roblox_compatibility.json}"
SIGNING_TRUST_PATH="${SIGHTER_UPDATE_SIGNING_TRUST_PATH:-${PROJECT_ROOT}/config/roblox_signing_certificates.json}"
PAYLOAD_STORE_SCRIPT="${PROJECT_ROOT}/scripts/payload_store.sh"

BASE_APK=""
SPLIT_APK=""
SOURCE_LABEL="sober-update-service"
DRY_RUN=false
ALLOW_DOWNGRADE=false
STORE_ROOT=""
TEMP_DIR=""
ROLLBACK_DIR=""
ROLLBACK_NEEDED=false

usage() {
  cat <<'EOF'
Usage: scripts/update_roblox_payload.sh [OPTIONS]

Import and validate a matching Roblox base APK and x86_64 split APK.
Without explicit paths, the latest bundle cached by Sober is used.

Options:
  --base APK          Path to base.apk.
  --x86-64 APK        Path to split_config.x86_64.apk.
  --source LABEL      Source label recorded in payload metadata.
  --signing-trust FILE  Trusted Roblox certificate digest manifest.
  --allow-downgrade   Permit a lower Android versionCode.
  --store-root DIR    Stage into the immutable XDG store without activating
                      the legacy rbx_bin payload.
  --dry-run           Validate and report without changing project files.
  -h, --help          Show this help.
EOF
}

log() {
  local -r level="$1"
  shift
  printf '[%s] %-5s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${level}" "$*" >&2
}

die() {
  log ERROR "$*"
  exit 1
}

require_commands() {
  local -a missing=()
  local command_name
  for command_name in aapt apksigner file flock jq readelf sha256sum sort unzip; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      missing+=("${command_name}")
    fi
  done
  if (( ${#missing[@]} != 0 )); then
    die "missing required commands: ${missing[*]}"
  fi
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --base)
        (( $# >= 2 )) || die "--base requires a path"
        BASE_APK="$2"
        shift 2
        ;;
      --x86-64)
        (( $# >= 2 )) || die "--x86-64 requires a path"
        SPLIT_APK="$2"
        shift 2
        ;;
      --source)
        (( $# >= 2 )) || die "--source requires a label"
        SOURCE_LABEL="$2"
        shift 2
        ;;
      --signing-trust)
        (( $# >= 2 )) || die "--signing-trust requires a path"
        SIGNING_TRUST_PATH="$2"
        shift 2
        ;;
      --allow-downgrade)
        ALLOW_DOWNGRADE=true
        shift
        ;;
      --store-root)
        (( $# >= 2 )) || die "--store-root requires a directory"
        STORE_ROOT="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  if [[ -n "${BASE_APK}" || -n "${SPLIT_APK}" ]]; then
    [[ -n "${BASE_APK}" && -n "${SPLIT_APK}" ]] ||
      die "--base and --x86-64 must be provided together"
    return
  fi

  local -r sober_package_dir="${HOME}/.var/app/org.vinegarhq.Sober/data/sober/packages/x86_64/com.roblox.client"
  BASE_APK="${sober_package_dir}/base.apk"
  SPLIT_APK="${sober_package_dir}/split_config.x86_64.apk"
}

apk_identity() {
  local -r apk="$1"
  aapt dump badging "${apk}" |
    sed -n "s/^package: name='\([^']*\)' versionCode='\([^']*\)' versionName='\([^']*\)'.*/\1|\2|\3/p" |
    head -n 1
}

certificate_digests() {
  local -r apk="$1"
  apksigner verify --verbose --print-certs "${apk}" 2>/dev/null |
    grep -E '^(V[0-9.]+ Signer:|Signer #[0-9]+ certificate)' |
    sed -n 's/.*certificate SHA-256 digest: \([[:xdigit:]]\{64\}\)$/\1/p' |
    sort -u
}

restore_payload() {
  [[ "${ROLLBACK_NEEDED}" == true && -d "${ROLLBACK_DIR}" ]] || return 0

  log WARN "restoring the previous payload"
  mkdir -p "${RBX_BIN_DIR}" "$(dirname -- "${METADATA_PATH}")"

  local path
  for path in libroblox.so sober_apk assets; do
    if [[ -e "${RBX_BIN_DIR}/${path}" ]]; then
      mv -- "${RBX_BIN_DIR}/${path}" "${TEMP_DIR}/failed-${path}"
    fi
    if [[ -e "${ROLLBACK_DIR}/${path}" ]]; then
      mv -- "${ROLLBACK_DIR}/${path}" "${RBX_BIN_DIR}/${path}"
    fi
  done

  if [[ -e "${METADATA_PATH}" ]]; then
    mv -- "${METADATA_PATH}" "${TEMP_DIR}/failed-metadata.json"
  fi
  if [[ -e "${ROLLBACK_DIR}/roblox_payload.json" ]]; then
    mv -- "${ROLLBACK_DIR}/roblox_payload.json" "${METADATA_PATH}"
  fi
}

cleanup() {
  local -r status=$?
  trap - EXIT
  set +e
  restore_payload
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
  exit "${status}"
}

snapshot_apks() {
  local -r stage_dir="$1"
  mkdir -p "${stage_dir}/sober_apk"

  cp -- "${BASE_APK}" "${stage_dir}/sober_apk/base.apk"
  cp -- "${SPLIT_APK}" "${stage_dir}/sober_apk/split_config.x86_64.apk"
}

extract_payload() {
  local -r stage_dir="$1"
  local -r base_apk="${stage_dir}/sober_apk/base.apk"
  local -r split_apk="${stage_dir}/sober_apk/split_config.x86_64.apk"
  mkdir -p "${stage_dir}/extracted"
  unzip -p "${split_apk}" 'lib/x86_64/libroblox.so' > "${stage_dir}/libroblox.so"
  unzip -q "${base_apk}" 'assets/*' -d "${stage_dir}/extracted"
  [[ -d "${stage_dir}/extracted/assets" ]] || die "base APK contains no assets directory"
  mv -- "${stage_dir}/extracted/assets" "${stage_dir}/assets"
  rmdir -- "${stage_dir}/extracted"
}

main() {
  parse_arguments "$@"
  require_commands

  # Serialise both validation and activation. The directory descriptor avoids
  # a persistent lock file while protecting the active payload namespace. A
  # store import must not write beside PROJECT_ROOT: portable/AppImage roots
  # may be mounted read-only, while the XDG payload store is writable.
  local workspace_dir="${RBX_BIN_DIR}"
  if [[ -n "${STORE_ROOT}" ]]; then
    workspace_dir="${STORE_ROOT}"
  fi
  mkdir -p "${workspace_dir}"
  exec 9<"${workspace_dir}"
  flock -n 9 || die "another Roblox payload update is already running"

  [[ -f "${BASE_APK}" && -r "${BASE_APK}" ]] || die "base APK is not readable: ${BASE_APK}"
  [[ -f "${SPLIT_APK}" && -r "${SPLIT_APK}" ]] || die "x86_64 split APK is not readable: ${SPLIT_APK}"

  # Snapshot the external bundle before inspecting it. Sober may atomically
  # replace its cache during an update; every check below must describe the
  # exact bytes that would become active, not a moving source path.
  TEMP_DIR="$(mktemp -d "${workspace_dir}/.payload-update.XXXXXX")"
  trap cleanup EXIT
  local -r stage_dir="${TEMP_DIR}/new"
  snapshot_apks "${stage_dir}"
  local -r staged_base_apk="${stage_dir}/sober_apk/base.apk"
  local -r staged_split_apk="${stage_dir}/sober_apk/split_config.x86_64.apk"

  local base_identity split_identity
  base_identity="$(apk_identity "${staged_base_apk}")"
  split_identity="$(apk_identity "${staged_split_apk}")"
  [[ -n "${base_identity}" && -n "${split_identity}" ]] || die "unable to read APK package metadata"

  local package_name version_code version_name split_package split_version_code split_version_name
  IFS='|' read -r package_name version_code version_name <<< "${base_identity}"
  IFS='|' read -r split_package split_version_code split_version_name <<< "${split_identity}"
  [[ "${package_name}" == "com.roblox.client" ]] || die "unexpected package: ${package_name}"
  [[ "${split_package}" == "${package_name}" && "${split_version_code}" == "${version_code}" ]] ||
    die "base and x86_64 split versions do not match"
  local split_layout="config.x86_64"
  if ! aapt dump badging "${staged_split_apk}" | sed -n '1p' |
       grep -Fq "split='config.x86_64'"; then
    local staged_base_hash staged_split_hash
    staged_base_hash="$(sha256sum "${staged_base_apk}" | awk '{print $1}')"
    staged_split_hash="$(sha256sum "${staged_split_apk}" | awk '{print $1}')"
    if [[ "${staged_base_hash}" == "${staged_split_hash}" ]]; then
      split_layout="monolithic"
    else
      die "the supplied split APK is neither config.x86_64 nor the base monolithic APK"
    fi
  fi
  [[ "${version_code}" =~ ^[0-9]+$ ]] || die "invalid versionCode: ${version_code}"

  unzip -Z1 "${staged_split_apk}" 'lib/x86_64/libroblox.so' 2>/dev/null |
    grep -Fxq 'lib/x86_64/libroblox.so' || die "split APK has no x86_64 libroblox.so"

  apksigner verify "${staged_base_apk}" >/dev/null 2>&1 || die "base APK signature verification failed"
  apksigner verify "${staged_split_apk}" >/dev/null 2>&1 || die "split APK signature verification failed"

  local -a base_certificates=() split_certificates=() common_certificates=()
  mapfile -t base_certificates < <(certificate_digests "${staged_base_apk}")
  mapfile -t split_certificates < <(certificate_digests "${staged_split_apk}")
  mapfile -t common_certificates < <(
    comm -12 <(printf '%s\n' "${base_certificates[@]}" | sort -u) \
      <(printf '%s\n' "${split_certificates[@]}" | sort -u)
  )
  (( ${#common_certificates[@]} > 0 )) || die "base and split APKs do not share a signing certificate"
  [[ -r "${SIGNING_TRUST_PATH}" ]] ||
    die "Roblox signing trust manifest is not readable: ${SIGNING_TRUST_PATH}"
  jq -e '.schema_version == 1 and .package == "com.roblox.client" and
         (.trusted_sha256 | type == "array" and length > 0) and
         all(.trusted_sha256[]; test("^[0-9a-fA-F]{64}$"))' \
    "${SIGNING_TRUST_PATH}" >/dev/null ||
    die "Roblox signing trust manifest is invalid"
  local -a trusted_certificates=() accepted_certificates=()
  mapfile -t trusted_certificates < <(
    jq -r '.trusted_sha256[] | ascii_downcase' "${SIGNING_TRUST_PATH}" | sort -u
  )
  mapfile -t accepted_certificates < <(
    comm -12 <(printf '%s\n' "${common_certificates[@]}" | tr '[:upper:]' '[:lower:]' | sort -u) \
      <(printf '%s\n' "${trusted_certificates[@]}" | sort -u)
  )
  (( ${#accepted_certificates[@]} > 0 )) ||
    die "APK signing certificate is not trusted for com.roblox.client"

  extract_payload "${stage_dir}"

  local machine build_id
  machine="$(LC_ALL=C readelf -h "${stage_dir}/libroblox.so" |
    sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
  [[ "${machine}" == "Advanced Micro Devices X86-64" ]] || die "unexpected ELF machine: ${machine}"
  LC_ALL=C file "${stage_dir}/libroblox.so" |
    grep -Fq 'for Android' || die "libroblox.so is not an Android ELF"
  build_id="$(LC_ALL=C readelf -n "${stage_dir}/libroblox.so" |
    awk '/Build ID:/ { print $3; exit }')"
  [[ "${build_id}" =~ ^[[:xdigit:]]{40}$ ]] || die "missing or invalid ELF Build ID"
  local -r dynamic_symbols="${TEMP_DIR}/libroblox.dynamic-symbols"
  LC_ALL=C readelf --wide --dyn-syms "${stage_dir}/libroblox.so" \
    > "${dynamic_symbols}"
  local -a required_startup_exports=(
    "JNI_OnLoad"
    "Java_com_roblox_engine_jni_NativeGLInterface_nativeGameGlobalInit"
    "Java_com_roblox_engine_jni_NativeGLInterface_nativeUpdateAdapterInit"
    "Java_com_roblox_engine_jni_NativeGLInterface_nativeAppBridgeV2InitWithParams"
    "Java_com_roblox_engine_jni_NativeGLInterface_nativeAppBridgeStartLuaAppDM"
    "Java_com_roblox_engine_jni_NativeGLInterface_nativeAppBridgeV2StartAppWithParams"
    "Java_com_roblox_engine_jni_NativeGLInterface_nativeAppBridgeV2UpdateSurfaceAppWithPlatformParams"
  )
  local required_export
  for required_export in "${required_startup_exports[@]}"; do
    grep -Fq "${required_export}" "${dynamic_symbols}" ||
      die "required startup export is missing: ${required_export}"
  done

  local current_version_code="" current_version_name="" current_build_id=""
  if [[ -f "${RBX_BIN_DIR}/sober_apk/base.apk" ]]; then
    local current_identity current_package
    current_identity="$(apk_identity "${RBX_BIN_DIR}/sober_apk/base.apk")"
    IFS='|' read -r current_package current_version_code current_version_name <<< "${current_identity}"
  fi
  if [[ -f "${RBX_BIN_DIR}/libroblox.so" ]]; then
    current_build_id="$(LC_ALL=C readelf -n "${RBX_BIN_DIR}/libroblox.so" |
      awk '/Build ID:/ { print $3; exit }')"
  fi

  if [[ "${ALLOW_DOWNGRADE}" == false && "${current_version_code}" =~ ^[0-9]+$ ]] &&
     (( version_code < current_version_code )); then
    die "refusing downgrade ${current_version_name} (${current_version_code}) -> ${version_name} (${version_code})"
  fi

  local lib_hash base_hash split_hash asset_count asset_tree_hash certificate_json
  lib_hash="$(sha256sum "${stage_dir}/libroblox.so" | awk '{ print $1 }')"
  base_hash="$(sha256sum "${stage_dir}/sober_apk/base.apk" | awk '{ print $1 }')"
  split_hash="$(sha256sum "${stage_dir}/sober_apk/split_config.x86_64.apk" | awk '{ print $1 }')"
  asset_count="$(find "${stage_dir}/assets" -type f -printf '.' | wc -c)"
  asset_tree_hash="$(PayloadAssetTreeSha256 "${stage_dir}/assets")"
  certificate_json="$(printf '%s\n' "${common_certificates[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"

  jq -n \
    --arg package "${package_name}" \
    --arg version_name "${version_name}" \
    --argjson version_code "${version_code}" \
    --arg abi "x86_64" \
    --arg build_id "${build_id}" \
    --arg lib_sha256 "${lib_hash}" \
    --arg base_sha256 "${base_hash}" \
    --arg split_sha256 "${split_hash}" \
    --arg source "${SOURCE_LABEL}" \
    --arg apk_layout "${split_layout}" \
    --arg imported_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson asset_count "${asset_count}" \
    --arg asset_tree_hash "${asset_tree_hash}" \
    --argjson signing_certificates "${certificate_json}" \
    '{schema_version: 1, package: $package, version_name: $version_name,
      version_code: $version_code, abi: $abi, elf_build_id: $build_id,
      sha256: {libroblox: $lib_sha256, base_apk: $base_sha256,
               x86_64_split_apk: $split_sha256},
      signing_certificates_sha256: $signing_certificates,
      assets: {file_count: $asset_count, sha256_tree: $asset_tree_hash},
      source: $source,
      imported_at: $imported_at, compatibility_status: "unverified",
      apk_layout: $apk_layout}' \
    > "${stage_dir}/roblox_payload.json"

  log INFO "validated Roblox ${version_name} (${version_code}), x86_64 Build ID ${build_id}"
  log INFO "payload contains ${asset_count} asset files"

  if [[ -n "${STORE_ROOT}" ]]; then
    [[ "${DRY_RUN}" == false ]] || {
      log INFO "dry-run complete; immutable store was not changed"
      return 0
    }
    [[ -x "${PAYLOAD_STORE_SCRIPT}" ]] ||
      die "payload store helper is unavailable: ${PAYLOAD_STORE_SCRIPT}"
    local payload_id
    payload_id="$(${PAYLOAD_STORE_SCRIPT} --root "${STORE_ROOT}" \
      --compatibility "${COMPATIBILITY_PATH}" stage "${stage_dir}")"
    log INFO "staged candidate ${payload_id} in immutable payload store"
    printf '%s\n' "${payload_id}"
    return 0
  fi

  if [[ -f "${RBX_BIN_DIR}/libroblox.so" &&
        "$(sha256sum "${RBX_BIN_DIR}/libroblox.so" | awk '{ print $1 }')" == "${lib_hash}" &&
        -f "${RBX_BIN_DIR}/sober_apk/base.apk" &&
        "$(sha256sum "${RBX_BIN_DIR}/sober_apk/base.apk" | awk '{ print $1 }')" == "${base_hash}" &&
        -f "${RBX_BIN_DIR}/sober_apk/split_config.x86_64.apk" &&
        "$(sha256sum "${RBX_BIN_DIR}/sober_apk/split_config.x86_64.apk" | awk '{ print $1 }')" == "${split_hash}" ]]; then
    log INFO "this payload is already active"
    return 0
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    log INFO "dry-run complete; no files changed"
    return 0
  fi

  mkdir -p "${VERSIONS_DIR}" "$(dirname -- "${METADATA_PATH}")"
  ROLLBACK_DIR="${TEMP_DIR}/rollback"
  mkdir -p "${ROLLBACK_DIR}"

  local active_path
  for active_path in libroblox.so sober_apk assets; do
    if [[ -e "${RBX_BIN_DIR}/${active_path}" ]]; then
      mv -- "${RBX_BIN_DIR}/${active_path}" "${ROLLBACK_DIR}/${active_path}"
    fi
  done
  if [[ -e "${METADATA_PATH}" ]]; then
    mv -- "${METADATA_PATH}" "${ROLLBACK_DIR}/roblox_payload.json"
  fi
  ROLLBACK_NEEDED=true

  mv -- "${stage_dir}/libroblox.so" "${RBX_BIN_DIR}/libroblox.so"
  mv -- "${stage_dir}/sober_apk" "${RBX_BIN_DIR}/sober_apk"
  mv -- "${stage_dir}/assets" "${RBX_BIN_DIR}/assets"
  mv -- "${stage_dir}/roblox_payload.json" "${METADATA_PATH}"

  if [[ -n "${current_version_name}" && -n "${current_build_id}" ]]; then
    local -r archive_path="${VERSIONS_DIR}/${current_version_name}-${current_build_id}"
    [[ ! -e "${archive_path}" ]] || die "archive already exists: ${archive_path}"
    mv -- "${ROLLBACK_DIR}" "${archive_path}"
    log INFO "archived previous payload at ${archive_path}"
  elif find "${ROLLBACK_DIR}" -mindepth 1 -print -quit | grep -q .; then
    local -r archive_path="${VERSIONS_DIR}/unknown-$(date -u +'%Y%m%dT%H%M%SZ')"
    mv -- "${ROLLBACK_DIR}" "${archive_path}"
    log WARN "archived unversioned previous payload at ${archive_path}"
  fi

  ROLLBACK_NEEDED=false
  log INFO "activated Roblox ${version_name}; compatibility remains unverified until runtime gates pass"
}

main "$@"

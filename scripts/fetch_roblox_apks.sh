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
SOURCE="apk-pure"
VERSION=""
STAGING_ROOT="${XDG_CACHE_HOME:-${HOME}/.cache}/sighter/apk-staging"
TEMP_DIR=""
PUBLISHED_DIR=""
COMMITTED=false
readonly PACKAGE="com.roblox.client"
readonly MAX_CANDIDATES=64
readonly MAX_APK_BYTES=1073741824

usage() {
  cat <<'EOF'
Usage: scripts/fetch_roblox_apks.sh [OPTIONS]

Download and stage the latest matching Roblox base and x86_64 split APKs.
The command never activates a payload. Pass the reported paths explicitly to
update_roblox_payload.sh only after its compatibility checks are appropriate.

Options:
  --source NAME         Download source. Uptodown is reserved for a pinned
                        bootstrap; normal updates use apk-pure.
  --version VERSION     APK version name.
  --staging-root DIR    Immutable bundle destination.
  -h, --help            Show this help.
EOF
}

log() {
  printf '[apk-fetch] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  local -r status=$?
  trap - EXIT
  if [[ "${COMMITTED}" == false && -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    chmod -R u+w "${TEMP_DIR}" 2>/dev/null || true
    rm -rf -- "${TEMP_DIR}"
  fi
  if [[ "${COMMITTED}" == false && -n "${PUBLISHED_DIR}" && -d "${PUBLISHED_DIR}" ]]; then
    chmod -R u+w "${PUBLISHED_DIR}" 2>/dev/null || true
    rm -rf -- "${PUBLISHED_DIR}"
  fi
  exit "${status}"
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --source)
        (( $# >= 2 )) || die "--source requires a name"
        SOURCE="$2"
        shift 2
        ;;
      --version)
        (( $# >= 2 )) || die "--version requires a value"
        VERSION="$2"
        shift 2
        ;;
      --staging-root)
        (( $# >= 2 )) || die "--staging-root requires a directory"
        STAGING_ROOT="$2"
        shift 2
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
}

require_commands() {
  local command_name
  for command_name in aapt flock jq sha256sum unzip; do
    command -v "${command_name}" >/dev/null 2>&1 ||
      die "missing required command: ${command_name}"
  done
}

apk_identity() {
  aapt dump badging "$1" 2>/dev/null |
    sed -n "s/^package: name='\([^']*\)' versionCode='\([^']*\)' versionName='\([^']*\)'.*/\1|\2|\3/p" |
    head -n 1
}

apk_split_name() {
  aapt dump badging "$1" 2>/dev/null |
    sed -n "1s/.* split='\([^']*\)'.*/\1/p"
}

copy_candidate() {
  local -r source_path="$1"
  local -r candidates_dir="$2"
  local -r candidate_number="$3"
  local -r destination="${candidates_dir}/candidate-$(printf '%03d' "${candidate_number}").apk"
  cp -- "${source_path}" "${destination}"
  [[ "$(stat -c '%s' "${destination}")" -le "${MAX_APK_BYTES}" ]] ||
    die "APK candidate exceeds the size limit"
}

collect_candidates() {
  local -r raw_dir="$1"
  local -r candidates_dir="$2"
  local count=0 path entry destination
  mkdir -p -- "${candidates_dir}"

  while IFS= read -r -d '' path; do
    (( count < MAX_CANDIDATES )) || die "provider produced too many APK candidates"
    ((count += 1))
    copy_candidate "${path}" "${candidates_dir}" "${count}"
  done < <(find "${raw_dir}" -maxdepth 3 -type f -name '*.apk' -size "-${MAX_APK_BYTES}c" -print0 | sort -z)

  while IFS= read -r -d '' path; do
    while IFS= read -r entry; do
      [[ "${entry}" == *.apk ]] || continue
      [[ "${entry}" != /* && "${entry}" != *'../'* && "${entry}" != '../'* ]] ||
        die "unsafe APK bundle entry: ${entry}"
      (( count < MAX_CANDIDATES )) || die "provider produced too many APK candidates"
      ((count += 1))
      destination="${candidates_dir}/candidate-$(printf '%03d' "${count}").apk"
      (ulimit -f $((MAX_APK_BYTES / 512)); unzip -p "${path}" "${entry}" > "${destination}") ||
        die "unable to extract APK bundle entry: ${entry}"
      [[ "$(stat -c '%s' "${destination}")" -le "${MAX_APK_BYTES}" ]] ||
        die "APK bundle entry exceeds the size limit"
    done < <(unzip -Z1 "${path}")
  done < <(find "${raw_dir}" -maxdepth 3 -type f \( -name '*.apks' -o -name '*.xapk' -o -name '*.zip' \) -print0 | sort -z)

  (( count > 0 )) || die "provider output contains no APK candidates"
}

classify_candidates() {
  local -r candidates_dir="$1"
  local -r records_path="$2"
  local path identity package version_code version_name split kind hash
  local record_version_name record_split
  : > "${records_path}"

  for path in "${candidates_dir}"/*.apk; do
    identity="$(apk_identity "${path}")"
    [[ -n "${identity}" ]] || continue
    IFS='|' read -r package version_code version_name <<< "${identity}"
    [[ "${package}" == "${PACKAGE}" && "${version_code}" =~ ^[0-9]+$ ]] || continue
    split="$(apk_split_name "${path}")"
    kind=""
    if [[ -z "${split}" ]]; then
      kind="base"
    elif [[ "${split}" == "config.x86_64" ]] &&
         unzip -Z1 "${path}" 'lib/x86_64/libroblox.so' 2>/dev/null |
           grep -Fxq 'lib/x86_64/libroblox.so'; then
      kind="x86_64"
    fi
    [[ -n "${kind}" ]] || continue
    hash="$(sha256sum "${path}" | awk '{print $1}')"
    record_version_name="${version_name:-__missing_version_name__}"
    record_split="${split:-__base__}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${version_code}" "${kind}" "${path}" "${record_version_name}" \
      "${hash}" "${record_split}" >> "${records_path}"
    if [[ "${kind}" == "base" ]] &&
       unzip -Z1 "${path}" 'lib/x86_64/libroblox.so' 2>/dev/null |
         grep -Fxq 'lib/x86_64/libroblox.so'; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${version_code}" "x86_64" "${path}" "${record_version_name}" \
        "${hash}" "monolithic" >> "${records_path}"
    fi
  done
  [[ -s "${records_path}" ]] || die "no usable Roblox APKs found"
}

select_pair() {
  local -r records_path="$1"
  local -r selected_path="$2"
  local version_code base_record split_record
  : > "${selected_path}"
  while IFS= read -r version_code; do
    base_record="$(awk -F '\t' -v version="${version_code}" '$1 == version && $2 == "base" {print; exit}' "${records_path}")"
    split_record="$(awk -F '\t' -v version="${version_code}" '$1 == version && $2 == "x86_64" {print; exit}' "${records_path}")"
    if [[ -n "${base_record}" && -n "${split_record}" ]]; then
      printf '%s\n%s\n' "${base_record}" "${split_record}" > "${selected_path}"
      return 0
    fi
  done < <(cut -f1 "${records_path}" | sort -nr -u)
  die "no matching Roblox base and config.x86_64 APK pair found"
}

main() {
  parse_arguments "$@"
  require_commands
  local provider
  case "${SOURCE}" in
    apk-pure) provider="direct_apkpure" ;;
    uptodown) provider="direct_uptodown" ;;
    *) die "unsupported download source: ${SOURCE}" ;;
  esac
  local -r provider_path="${SIGHTER_APK_PROVIDER_COMMAND:-${SCRIPT_DIR}/apk_providers/${provider}.sh}"
  [[ -x "${provider_path}" ]] || die "download provider is unavailable: ${provider_path}"

  mkdir -p -- "${STAGING_ROOT}"
  exec 9<"${STAGING_ROOT}"
  flock -n 9 || die "another APK fetch is already using this staging root"
  TEMP_DIR="$(mktemp -d "${STAGING_ROOT}/.fetch.XXXXXX")"
  trap cleanup EXIT
  mkdir -p -- "${TEMP_DIR}/raw"

  local -a provider_arguments=(
    --package "${PACKAGE}" --output "${TEMP_DIR}/raw" --source "${SOURCE}"
  )
  [[ -z "${VERSION}" ]] || provider_arguments+=(--version "${VERSION}")
  "${provider_path}" "${provider_arguments[@]}" >&2

  collect_candidates "${TEMP_DIR}/raw" "${TEMP_DIR}/candidates"
  classify_candidates "${TEMP_DIR}/candidates" "${TEMP_DIR}/records.tsv"
  select_pair "${TEMP_DIR}/records.tsv" "${TEMP_DIR}/selected.tsv"

  local base_path split_path version_code version_name base_hash split_hash ignored
  IFS=$'\t' read -r version_code ignored base_path version_name base_hash ignored < "${TEMP_DIR}/selected.tsv"
  IFS=$'\t' read -r ignored ignored split_path ignored split_hash ignored < <(sed -n '2p' "${TEMP_DIR}/selected.tsv")
  if [[ -n "${VERSION}" && "${version_name}" != "${VERSION}" ]]; then
    die "provider returned versionName ${version_name}, expected ${VERSION}"
  fi
  local -r bundle_id="${version_code}-${base_hash:0:12}-${split_hash:0:12}"
  local -r final_dir="${STAGING_ROOT}/${PACKAGE}-${bundle_id}"
  if [[ -d "${final_dir}" && -f "${final_dir}/download.json" ]] &&
     [[ "$(jq -r '.sha256.base_apk // empty' "${final_dir}/download.json")" == "${base_hash}" ]] &&
     [[ "$(jq -r '.sha256.x86_64_split_apk // empty' "${final_dir}/download.json")" == "${split_hash}" ]]; then
    log "bundle is already staged: ${final_dir}"
    printf '%s\n' "${final_dir}"
    return 0
  fi
  [[ ! -e "${final_dir}" ]] || die "immutable staged bundle collision: ${final_dir}"

  mkdir -p -- "${TEMP_DIR}/bundle"
  cp -- "${base_path}" "${TEMP_DIR}/bundle/base.apk"
  cp -- "${split_path}" "${TEMP_DIR}/bundle/split_config.x86_64.apk"
  jq -n \
    --arg package "${PACKAGE}" \
    --arg version_name "${version_name}" \
    --argjson version_code "${version_code}" \
    --arg provider "${provider}" \
    --arg source "${SOURCE}" \
    --arg base_sha256 "${base_hash}" \
    --arg split_sha256 "${split_hash}" \
    '{schema_version: 1, state: "downloaded", activated: false,
      package: $package, version_name: $version_name, version_code: $version_code,
      abi: "x86_64", provider: $provider, source: $source,
      files: {base: "base.apk", x86_64_split: "split_config.x86_64.apk"},
      sha256: {base_apk: $base_sha256, x86_64_split_apk: $split_sha256}}' \
    > "${TEMP_DIR}/bundle/download.json"
  PUBLISHED_DIR="${final_dir}"
  mv -- "${TEMP_DIR}/bundle" "${final_dir}"
  chmod -R a-w "${final_dir}"
  COMMITTED=true
  rm -rf -- "${TEMP_DIR}"
  log "staged Roblox ${version_name} (${version_code}) at ${final_dir}; payload was not activated"
  printf '%s\n' "${final_dir}"
}

main "$@"

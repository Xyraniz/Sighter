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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/payload_integrity.sh"

STORE_ROOT="${SIGHTER_PAYLOAD_STORE_ROOT:-${XDG_DATA_HOME:-${HOME}/.local/share}/sighter}"
COMPATIBILITY_PATH=""
EXPECTED_CURRENT=""
EXPECTED_PAYLOAD_FINGERPRINT=""
EXPECTED_ROLLBACK_TARGET=""
CANDIDATE_PROFILE_PATH=""
CANDIDATE_COMPATIBILITY_PATH=""
RUNTIME_FINGERPRINT=""
RUNTIME_BUILD_ID=""
CANARY_ATTESTATION_PATHS=()
PROMOTION_APPROVAL_GENERATION=""

Log() {
  printf '[payload-store] %s\n' "$*" >&2
}

Die() {
  Log "error: $*"
  exit 1
}

Usage() {
  cat <<'EOF'
Usage: scripts/payload_store.sh [GLOBAL OPTIONS] COMMAND [ARGUMENTS]

Immutable Roblox payload staging and atomic activation.

Global options:
  --root DIR            Override the XDG payload store root.
  --compatibility FILE  Build-ID compatibility profile used by promotion.
  --expected-current ID Require current payload ID to remain unchanged. Use
                        "none" when no payload may already be active.
  --expected-payload-fingerprint SHA256
                        Require the candidate bytes observed before canary.
  --expected-rollback-target ID
                        Require previous-good to match a known baseline.
  --candidate-profile FILE
                        Derived exact host-ABI profile for probation promotion.
  --candidate-compatibility FILE
                        One-payload compatibility manifest used by probation.
  --runtime-fingerprint SHA256
                        Bind approval to the canary runtime executable bytes.
  --runtime-build-id HEX
                        Bind approval to the installed runtime ELF Build ID.
  --canary-attestation FILE
                        Passed Tier C attestation. Supply exactly twice for
                        probation promotion.

Commands:
  stage PAYLOAD_DIR     Validate and immutably stage a prepared payload.
  import PAYLOAD_DIR    Stage, then promote only an exact supported Build ID.
  promote PAYLOAD_ID    Atomically activate an exact supported payload.
  promote-probation PAYLOAD_ID
                        Approve and activate a double-canary candidate.
  fingerprint PAYLOAD_ID
                        Verify and fingerprint immutable runtime bytes.
  verify-current        Verify current manifest, payload bytes, and any
                        probation approval generation; print its payload ID.
  rollback              Restore current.json from previous_good.json.
  status                Print current and previous-good manifests.

PAYLOAD_DIR must contain libroblox.so, assets/, sober_apk/base.apk,
sober_apk/split_config.x86_64.apk, and roblox_payload.json. APK/ELF validation
belongs to update_roblox_payload.sh; this command verifies the resulting hashes
and metadata before crossing the immutable store boundary.
EOF
}

RequireCommands() {
  local command_name
  for command_name in flock jq sha256sum sort; do
    command -v "${command_name}" >/dev/null 2>&1 ||
      Die "missing required command: ${command_name}"
  done
}

ParseGlobalOptions() {
  while (( $# > 0 )); do
    case "$1" in
      --root)
        (( $# >= 2 )) || Die "--root requires a directory"
        STORE_ROOT="$2"
        shift 2
        ;;
      --compatibility)
        (( $# >= 2 )) || Die "--compatibility requires a file"
        COMPATIBILITY_PATH="$2"
        shift 2
        ;;
      --expected-current)
        (( $# >= 2 )) || Die "--expected-current requires a payload ID or none"
        EXPECTED_CURRENT="$2"
        shift 2
        ;;
      --expected-payload-fingerprint)
        (( $# >= 2 )) ||
          Die "--expected-payload-fingerprint requires a SHA-256 digest"
        EXPECTED_PAYLOAD_FINGERPRINT="$2"
        shift 2
        ;;
      --expected-rollback-target)
        (( $# >= 2 )) ||
          Die "--expected-rollback-target requires a payload ID"
        EXPECTED_ROLLBACK_TARGET="$2"
        shift 2
        ;;
      --candidate-profile)
        (( $# >= 2 )) || Die "--candidate-profile requires a file"
        CANDIDATE_PROFILE_PATH="$2"
        shift 2
        ;;
      --candidate-compatibility)
        (( $# >= 2 )) || Die "--candidate-compatibility requires a file"
        CANDIDATE_COMPATIBILITY_PATH="$2"
        shift 2
        ;;
      --runtime-fingerprint)
        (( $# >= 2 )) || Die "--runtime-fingerprint requires a SHA-256 digest"
        RUNTIME_FINGERPRINT="$2"
        shift 2
        ;;
      --runtime-build-id)
        (( $# >= 2 )) || Die "--runtime-build-id requires a hex Build ID"
        RUNTIME_BUILD_ID="${2,,}"
        shift 2
        ;;
      --canary-attestation)
        (( $# >= 2 )) || Die "--canary-attestation requires a file"
        CANARY_ATTESTATION_PATHS+=("$2")
        shift 2
        ;;
      -h|--help)
        Usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        Die "unknown global option: $1"
        ;;
      *)
        break
        ;;
    esac
  done
  REMAINING_ARGUMENTS=("$@")
}

MetadataPath() {
  printf '%s/roblox_payload.json\n' "$1"
}

PayloadFingerprint() {
  jq -Sc '{schema_version, package, version_name, version_code, abi,
            elf_build_id: (.elf_build_id | ascii_downcase), sha256, assets}' \
    "$(MetadataPath "$1")"
}

ReadPayloadId() {
  local -r payload_dir="$1"
  local -r metadata="$(MetadataPath "${payload_dir}")"
  [[ -f "${metadata}" ]] || Die "payload metadata is missing: ${metadata}"

  local version_code build_id
  version_code="$(jq -er '.version_code | select(type == "number" and floor == . and . >= 0)' "${metadata}")" ||
    Die "payload metadata has an invalid version_code"
  build_id="$(jq -er '.elf_build_id | ascii_downcase | select(test("^[0-9a-f]{40}$"))' "${metadata}")" ||
    Die "payload metadata has an invalid ELF Build ID"
  printf '%s-%s\n' "${version_code}" "${build_id}"
}

ReadManifestPayloadId() {
  local -r manifest="$1"
  [[ -f "${manifest}" && ! -L "${manifest}" ]] ||
    Die "payload manifest is not a regular file: ${manifest}"
  jq -er '
    select(.schema_version == 1) |
    select((.payload_id | type) == "string" and
      (.payload_id | test("^[0-9]+-[0-9a-f]{40}$"))) |
    select(.payload_path == ("payloads/" + .payload_id)) |
    select((.version_code | type) == "number" and
      (.version_code | floor == . and . >= 0)) |
    select((.elf_build_id | type) == "string" and
      (.elf_build_id | test("^[0-9a-f]{40}$"))) |
    select(.payload_id == ((.version_code | tostring) + "-" +
      (.elf_build_id | ascii_downcase))) |
    .payload_id
  ' "${manifest}" || Die "payload manifest is invalid: ${manifest}"
}

VerifyPayload() {
  local -r payload_dir="$1"
  [[ -d "${payload_dir}" ]] || Die "payload directory is not readable: ${payload_dir}"

  local required_path
  for required_path in \
    libroblox.so \
    sober_apk/base.apk \
    sober_apk/split_config.x86_64.apk \
    roblox_payload.json; do
    [[ -f "${payload_dir}/${required_path}" ]] ||
      Die "prepared payload is missing ${required_path}"
  done
  [[ -d "${payload_dir}/assets" ]] || Die "prepared payload is missing assets/"
  if find -P "${payload_dir}" -type l -print -quit | grep -q .; then
    Die "prepared payload must not contain symbolic links"
  fi

  local -r metadata="$(MetadataPath "${payload_dir}")"
  jq -e '
    .schema_version == 1 and
    .package == "com.roblox.client" and
    .abi == "x86_64" and
    (.version_name | type == "string" and length > 0) and
    (.sha256.libroblox | test("^[0-9a-f]{64}$")) and
    (.sha256.base_apk | test("^[0-9a-f]{64}$")) and
    (.sha256.x86_64_split_apk | test("^[0-9a-f]{64}$"))
  ' "${metadata}" >/dev/null || Die "prepared payload metadata is incomplete"

  local expected actual relative_path
  while IFS='|' read -r relative_path expected; do
    actual="$(sha256sum "${payload_dir}/${relative_path}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]] || Die "hash mismatch for ${relative_path}"
  done < <(jq -r '
    ["libroblox.so", .sha256.libroblox],
    ["sober_apk/base.apk", .sha256.base_apk],
    ["sober_apk/split_config.x86_64.apk", .sha256.x86_64_split_apk] |
    @tsv
  ' "${metadata}" | tr '\t' '|')

  local expected_assets actual_assets
  expected_assets="$(jq -er '.assets.file_count | select(type == "number" and floor == . and . >= 0)' "${metadata}")" ||
    Die "payload metadata has an invalid asset count"
  actual_assets="$(find -P "${payload_dir}/assets" -type f -printf . | wc -c)"
  [[ "${actual_assets}" == "${expected_assets}" ]] || Die "asset count mismatch"

  local expected_asset_tree actual_asset_tree
  expected_asset_tree="$(jq -r '.assets.sha256_tree // empty' "${metadata}")"
  if [[ -n "${expected_asset_tree}" ]]; then
    [[ "${expected_asset_tree}" =~ ^[0-9a-f]{64}$ ]] ||
      Die "payload metadata has an invalid asset tree hash"
    actual_asset_tree="$(PayloadAssetTreeSha256 "${payload_dir}/assets")"
    [[ "${actual_asset_tree}" == "${expected_asset_tree}" ]] ||
      Die "asset tree hash mismatch"
  fi
}

RequirePayloadIdentity() {
  local -r payload_id="$1"
  local derived_payload_id
  derived_payload_id="$(ReadPayloadId "${STORE_ROOT}/payloads/${payload_id}")"
  [[ "${derived_payload_id}" == "${payload_id}" ]] ||
    Die "payload directory identity mismatch: expected ${payload_id}, found ${derived_payload_id}"
}

PayloadRuntimeFingerprint() {
  local -r payload_id="$1"
  local -r payload_dir="${STORE_ROOT}/payloads/${payload_id}"
  RequirePayloadIdentity "${payload_id}"
  VerifyPayload "${payload_dir}"
  local metadata_hash lib_hash base_hash split_hash asset_tree_hash
  metadata_hash="$(sha256sum "${payload_dir}/roblox_payload.json" | awk '{print $1}')"
  lib_hash="$(sha256sum "${payload_dir}/libroblox.so" | awk '{print $1}')"
  base_hash="$(sha256sum "${payload_dir}/sober_apk/base.apk" | awk '{print $1}')"
  split_hash="$(sha256sum "${payload_dir}/sober_apk/split_config.x86_64.apk" | awk '{print $1}')"
  asset_tree_hash="$(PayloadAssetTreeSha256 "${payload_dir}/assets")"
  printf 'payload_id=%s\nmetadata=%s\nlibroblox=%s\nbase_apk=%s\nx86_64_split=%s\nassets=%s\n' \
    "${payload_id}" "${metadata_hash}" "${lib_hash}" "${base_hash}" \
    "${split_hash}" "${asset_tree_hash}" |
    sha256sum | awk '{print $1}'
}

AcquireStoreLock() {
  mkdir -p "${STORE_ROOT}/payloads"
  exec 9>"${STORE_ROOT}/.payload-store.lock"
  flock 9
}

StagePayload() {
  local payload_dir
  payload_dir="$(cd -- "$1" && pwd -P)"
  VerifyPayload "${payload_dir}"
  local payload_id
  payload_id="$(ReadPayloadId "${payload_dir}")"
  local -r destination="${STORE_ROOT}/payloads/${payload_id}"

  if [[ -e "${destination}" || -L "${destination}" ]]; then
    if [[ -d "${destination}" && ! -L "${destination}" ]] &&
       (VerifyPayload "${destination}") 2>/dev/null; then
      [[ "$(PayloadFingerprint "${payload_dir}")" == "$(PayloadFingerprint "${destination}")" ]] ||
        Die "immutable payload ID collision: ${payload_id}"
      Log "payload already staged: ${payload_id}"
      printf '%s\n' "${payload_id}"
      return 0
    fi
    local -r quarantine_root="${STORE_ROOT}/quarantine"
    local -r quarantine_path="${quarantine_root}/${payload_id}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "${quarantine_root}"
    mv -- "${destination}" "${quarantine_path}"
    Log "quarantined corrupt immutable payload: ${quarantine_path}"
  fi

  local staging_dir
  staging_dir="$(mktemp -d "${STORE_ROOT}/payloads/.stage-${payload_id}.XXXXXX")"
  trap 'rm -rf -- "${staging_dir}"' RETURN
  cp -a -- "${payload_dir}/." "${staging_dir}/"
  VerifyPayload "${staging_dir}"
  chmod -R a-w "${staging_dir}"
  mv -- "${staging_dir}" "${destination}"
  trap - RETURN
  Log "staged immutable payload: ${payload_id}"
  printf '%s\n' "${payload_id}"
}

IsSupportedProfile() {
  local -r payload_id="$1"
  local -r metadata="${STORE_ROOT}/payloads/${payload_id}/roblox_payload.json"
  [[ -f "${metadata}" ]] || return 1
  [[ -n "${COMPATIBILITY_PATH}" && -r "${COMPATIBILITY_PATH}" ]] || return 1

  local build_id version_code
  build_id="$(jq -r '.elf_build_id | ascii_downcase' "${metadata}")"
  version_code="$(jq -r '.version_code' "${metadata}")"
  jq -e --arg build_id "${build_id}" --argjson version_code "${version_code}" '
    any(.profiles[]?;
      (.elf_build_id | ascii_downcase) == $build_id and
      .version_code == $version_code and
      .status == "supported" and
      .default_allowed == true and
      .allow_legacy_binary_patches == false)
  ' "${COMPATIBILITY_PATH}" >/dev/null
}

ApprovalReceiptPath() {
  printf '%s/approvals/%s-%s.json\n' "${STORE_ROOT}" "$1" "$2"
}

ApprovedProfilePath() {
  printf '%s/host_abi_profiles/%s-%s.json\n' "${STORE_ROOT}" "$1" "$2"
}

ApprovedCompatibilityPath() {
  printf '%s/compatibility_profiles/%s-%s.json\n' "${STORE_ROOT}" "$1" "$2"
}

ApprovedCanaryPath() {
  printf '%s/approvals/%s-%s.canary-%s.json\n' \
    "${STORE_ROOT}" "$1" "$2" "$3"
}

ManifestApprovalGeneration() {
  local -r manifest="$1"
  local -r payload_id="$2"
  local approval_path profile_path compatibility_path generation
  approval_path="$(jq -er '.approval_path | select(type == "string")' \
    "${manifest}" 2>/dev/null || true)"
  profile_path="$(jq -er '.host_abi_profile_path |
    select(type == "string")' "${manifest}" 2>/dev/null || true)"
  compatibility_path="$(jq -er '.compatibility_manifest_path |
    select(type == "string")' "${manifest}" 2>/dev/null || true)"
  if [[ "${approval_path}" =~ ^approvals/${payload_id}-([0-9a-f]{40})\.json$ ]]; then
    generation="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  [[ "${profile_path}" == \
       "host_abi_profiles/${payload_id}-${generation}.json" &&
     "${compatibility_path}" == \
       "compatibility_profiles/${payload_id}-${generation}.json" ]] ||
    return 1
  printf '%s\n' "${generation}"
}

IsExactCandidateProfile() {
  local -r payload_id="$1"
  local -r profile_path="$2"
  local -r payload_dir="${STORE_ROOT}/payloads/${payload_id}"
  local -r metadata="${payload_dir}/roblox_payload.json"
  [[ -f "${profile_path}" && ! -L "${profile_path}" ]] || return 1

  local build_id version_code libroblox_sha256
  build_id="$(jq -er '.elf_build_id | ascii_downcase |
    select(test("^[0-9a-f]{40}$"))' "${metadata}" 2>/dev/null)" || return 1
  version_code="$(jq -er '.version_code |
    select(type == "number" and floor == . and . >= 0)' \
    "${metadata}" 2>/dev/null)" || return 1
  libroblox_sha256="$(jq -er '.sha256.libroblox |
    select(test("^[0-9a-f]{64}$"))' "${metadata}" 2>/dev/null)" || return 1

  jq -e --arg payload_id "${payload_id}" \
    --arg payload_path "payloads/${payload_id}" \
    --arg build_id "${build_id}" \
    --arg payload_sha256 "${libroblox_sha256}" '
      .schema_version == 1 and
      .payload_id == $payload_id and
      .payload_path == $payload_path and
      (.elf_build_id | ascii_downcase) == $build_id and
      .payload_sha256 == $payload_sha256 and
      (.reference | type) == "object" and
      (.profile | type) == "object" and
      (.profile.bridge_entries | type) == "array" and
      (.profile.data_seeds | type) == "object" and
      (.profile.native_allocator | type) == "object" and
      (.profile.constructor_run_ranges | type) == "array" and
      (.profile.native_mimalloc_constructor_run_ranges | type) == "array" and
      (.profile.native_pre_jni_bootstrap | type) == "object" and
      .profile.default_allocator_strategy == "native_mimalloc"
    ' "${profile_path}" >/dev/null
}

IsExactCandidateCompatibility() {
  local -r payload_id="$1"
  local -r manifest_path="$2"
  local -r metadata="${STORE_ROOT}/payloads/${payload_id}/roblox_payload.json"
  [[ -f "${manifest_path}" && ! -L "${manifest_path}" ]] || return 1
  local build_id version_code
  build_id="$(jq -er '.elf_build_id | ascii_downcase' "${metadata}" 2>/dev/null)" || return 1
  version_code="$(jq -er '.version_code' "${metadata}" 2>/dev/null)" || return 1
  jq -e --arg build_id "${build_id}" --argjson version_code "${version_code}" '
    .schema_version == 1 and
    (.profiles | type) == "array" and
    (.profiles | length) == 1 and
    .profiles[0].version_code == $version_code and
    (.profiles[0].elf_build_id | ascii_downcase) == $build_id and
    .profiles[0].status == "experimental" and
    .profiles[0].default_allowed == true and
    .profiles[0].allow_legacy_binary_patches == false and
    .profiles[0].allow_host_abi_bridges == true and
    .profiles[0].allow_host_constructor_replay == true
  ' "${manifest_path}" >/dev/null
}

IsApprovedProfile() {
  local -r payload_id="$1"
  local -r generation="$2"
  [[ "${generation}" =~ ^[0-9a-f]{40}$ ]] || return 1
  local -r receipt="$(ApprovalReceiptPath "${payload_id}" "${generation}")"
  local -r profile="$(ApprovedProfilePath "${payload_id}" "${generation}")"
  local -r compatibility="$(ApprovedCompatibilityPath \
    "${payload_id}" "${generation}")"
  local -r canary_one="$(ApprovedCanaryPath \
    "${payload_id}" "${generation}" 1)"
  local -r canary_two="$(ApprovedCanaryPath \
    "${payload_id}" "${generation}" 2)"
  local regular_path
  for regular_path in "${receipt}" "${profile}" "${compatibility}" \
      "${canary_one}" "${canary_two}"; do
    [[ -f "${regular_path}" && ! -L "${regular_path}" ]] || return 1
  done
  IsExactCandidateProfile "${payload_id}" "${profile}" || return 1
  IsExactCandidateCompatibility "${payload_id}" "${compatibility}" || return 1

  local payload_fingerprint libroblox_sha256 profile_sha256
  local compatibility_sha256 canary_one_sha256 canary_two_sha256
  payload_fingerprint="$(PayloadRuntimeFingerprint "${payload_id}" 2>/dev/null)" || return 1
  libroblox_sha256="$(sha256sum \
    "${STORE_ROOT}/payloads/${payload_id}/libroblox.so" | awk '{print $1}')"
  profile_sha256="$(sha256sum "${profile}" | awk '{print $1}')"
  compatibility_sha256="$(sha256sum "${compatibility}" | awk '{print $1}')"
  canary_one_sha256="$(sha256sum "${canary_one}" | awk '{print $1}')"
  canary_two_sha256="$(sha256sum "${canary_two}" | awk '{print $1}')"
  local canonical_library
  canonical_library="$(cd -- "${STORE_ROOT}/payloads/${payload_id}" && pwd -P)/libroblox.so"
  local receipt_runtime_sha256 receipt_runtime_build_id expected_generation
  receipt_runtime_sha256="$(jq -er '.canary_runtime_sha256 |
    select(test("^[0-9a-f]{64}$"))' "${receipt}")" || return 1
  receipt_runtime_build_id="$(jq -er '.runtime_build_id |
    select(test("^[0-9a-f]{40}$"))' "${receipt}")" || return 1
  expected_generation="$(printf '%s\n' \
      "runtime_build_id=${receipt_runtime_build_id}" \
      "payload=${payload_fingerprint}" \
      "profile=${profile_sha256}" \
      "compatibility=${compatibility_sha256}" \
      "canary_1=${canary_one_sha256}" \
      "canary_2=${canary_two_sha256}" |
    sha256sum | awk '{print substr($1, 1, 40)}')"
  [[ "${generation}" == "${expected_generation}" ]] || return 1

  jq -e --arg payload_id "${payload_id}" \
    --arg generation "${generation}" \
    --arg payload_path "${canonical_library}" \
    --arg build_id "${payload_id#*-}" \
    --arg payload_sha256 "${libroblox_sha256}" \
    --arg payload_fingerprint "${payload_fingerprint}" \
    --arg profile_sha256 "${profile_sha256}" \
    --arg compatibility_sha256 "${compatibility_sha256}" \
    --arg canary_one_sha256 "${canary_one_sha256}" \
    --arg canary_two_sha256 "${canary_two_sha256}" \
    --arg runtime_sha256 "${receipt_runtime_sha256}" \
    --arg runtime_build_id "${receipt_runtime_build_id}" '
      .schema_version == 1 and .status == "approved" and
      .generation == $generation and
      .payload_id == $payload_id and .payload_path == $payload_path and
      (.elf_build_id | ascii_downcase) == $build_id and
      .payload_sha256 == $payload_sha256 and
      .payload_fingerprint == $payload_fingerprint and
      .profile_sha256 == $profile_sha256 and
      .compatibility_manifest_sha256 == $compatibility_sha256 and
      .canary_runtime_sha256 == $runtime_sha256 and
      .runtime_sha256 == $runtime_sha256 and
      .runtime_build_id == $runtime_build_id and
      .canary_tier == "C" and .successful_runs == 2 and
      .canary_attestation_sha256 ==
        [$canary_one_sha256, $canary_two_sha256]
    ' "${receipt}" >/dev/null || return 1
  VerifyCanaryAttestation "${canary_one}" 1 "${payload_id}" \
    "${payload_fingerprint}" "${profile_sha256}" \
    "${compatibility_sha256}" "${receipt_runtime_sha256}" \
    "${receipt_runtime_build_id}" || return 1
  VerifyCanaryAttestation "${canary_two}" 2 "${payload_id}" \
    "${payload_fingerprint}" "${profile_sha256}" \
    "${compatibility_sha256}" "${receipt_runtime_sha256}" \
    "${receipt_runtime_build_id}" || return 1
  [[ "$(jq -er '.run_id' "${canary_one}")" != \
     "$(jq -er '.run_id' "${canary_two}")" ]]
}

ValidateManifestPayload() {
  local -r manifest="$1"
  local payload_id approval_generation=""
  payload_id="$(ReadManifestPayloadId "${manifest}")"
  if IsSupportedProfile "${payload_id}"; then
    RequireSupportedProfile "${payload_id}"
  else
    approval_generation="$(ManifestApprovalGeneration \
      "${manifest}" "${payload_id}")" ||
      Die "approved payload manifest has invalid approval references"
    RequireSupportedProfile "${payload_id}" "${approval_generation}"
  fi
  printf '%s|%s\n' "${payload_id}" "${approval_generation}"
}

RequireSupportedProfile() {
  local -r payload_id="$1"
  local -r approval_generation="${2:-}"
  [[ -d "${STORE_ROOT}/payloads/${payload_id}" ]] || Die "payload is not staged: ${payload_id}"
  RequirePayloadIdentity "${payload_id}"
  [[ -n "${COMPATIBILITY_PATH}" && -r "${COMPATIBILITY_PATH}" ]] ||
    Die "promotion requires --compatibility FILE"
  if ! IsSupportedProfile "${payload_id}" &&
     ! IsApprovedProfile "${payload_id}" "${approval_generation}"; then
    Die "payload ${payload_id} is neither exact-supported nor probation-approved"
  fi
  VerifyPayload "${STORE_ROOT}/payloads/${payload_id}"
}

CurrentPayloadId() {
  local -r current="${STORE_ROOT}/current.json"
  if [[ ! -e "${current}" && ! -L "${current}" ]]; then
    printf 'none\n'
    return 0
  fi
  local manifest_identity payload_id
  manifest_identity="$(ValidateManifestPayload "${current}")"
  payload_id="${manifest_identity%%|*}"
  printf '%s\n' "${payload_id}"
}

RequireExpectedCurrent() {
  [[ -n "${EXPECTED_CURRENT}" ]] || return 0
  [[ "${EXPECTED_CURRENT}" == none ||
     "${EXPECTED_CURRENT}" =~ ^[0-9]+-[0-9a-f]{40}$ ]] ||
    Die "--expected-current has an invalid payload ID"
  local actual
  actual="$(CurrentPayloadId)"
  [[ "${actual}" == "${EXPECTED_CURRENT}" ]] ||
    Die "current payload changed during update: expected ${EXPECTED_CURRENT}, found ${actual}"
}

WriteManifest() {
  local -r payload_id="$1"
  local -r destination="$2"
  local -r approval_generation="${3:-}"
  local -r metadata="${STORE_ROOT}/payloads/${payload_id}/roblox_payload.json"
  local temporary
  temporary="$(mktemp "${STORE_ROOT}/.manifest.XXXXXX")"
  local approved=false
  if ! IsSupportedProfile "${payload_id}" &&
     IsApprovedProfile "${payload_id}" "${approval_generation}"; then
    approved=true
  fi
  if ! jq -n \
    --arg payload_id "${payload_id}" \
    --arg payload_path "payloads/${payload_id}" \
    --arg version_name "$(jq -r '.version_name' "${metadata}")" \
    --argjson version_code "$(jq -r '.version_code' "${metadata}")" \
    --arg build_id "$(jq -r '.elf_build_id | ascii_downcase' "${metadata}")" \
    --arg activated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson approved "${approved}" \
    --arg approval_path \
      "approvals/${payload_id}-${approval_generation}.json" \
    --arg profile_path \
      "host_abi_profiles/${payload_id}-${approval_generation}.json" \
    --arg compatibility_path \
      "compatibility_profiles/${payload_id}-${approval_generation}.json" \
    '{schema_version: 1, payload_id: $payload_id, payload_path: $payload_path,
      version_name: $version_name, version_code: $version_code,
      elf_build_id: $build_id, activated_at: $activated_at} +
      (if $approved then {
        approval_path: $approval_path,
        host_abi_profile_path: $profile_path,
        compatibility_manifest_path: $compatibility_path
      } else {} end)' > "${temporary}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  if ! chmod 0644 "${temporary}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  if ! mv -f -- "${temporary}" "${destination}"; then
    rm -f -- "${temporary}"
    return 1
  fi
}

CopyApprovalArtifact() {
  local -r source_path="$1"
  local -r destination_path="$2"
  local -r expected_sha256="$3"
  [[ -f "${source_path}" && ! -L "${source_path}" ]] ||
    Die "approval input is not a regular file: ${source_path}"
  [[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] ||
    Die "approval artifact has an invalid expected hash"
  mkdir -p -- "${destination_path%/*}"
  if [[ -e "${destination_path}" || -L "${destination_path}" ]]; then
    [[ -f "${destination_path}" && ! -L "${destination_path}" &&
       "$(sha256sum "${destination_path}" | awk '{print $1}')" == \
         "${expected_sha256}" ]] ||
      Die "immutable approval generation collision: ${destination_path}"
    return 0
  fi
  local temporary_path
  temporary_path="$(mktemp "${destination_path%/*}/.approval-artifact.XXXXXX")"
  if ! cp -- "${source_path}" "${temporary_path}" ||
     [[ "$(sha256sum "${temporary_path}" | awk '{print $1}')" != \
        "${expected_sha256}" ]] ||
     ! chmod 0444 -- "${temporary_path}" ||
     ! mv -- "${temporary_path}" "${destination_path}"; then
    rm -f -- "${temporary_path}"
    Die "failed to persist an approval artifact"
  fi
}

VerifyCanaryAttestation() {
  local -r attestation_path="$1"
  local -r expected_run="$2"
  local -r payload_id="$3"
  local -r payload_fingerprint="$4"
  local -r profile_sha256="$5"
  local -r compatibility_sha256="$6"
  local -r runtime_sha256="$7"
  local -r runtime_build_id="$8"
  [[ -f "${attestation_path}" && ! -L "${attestation_path}" ]] || return 1
  jq -e --argjson run "${expected_run}" \
    --arg payload_id "${payload_id}" \
    --arg payload_fingerprint "${payload_fingerprint}" \
    --arg profile_sha256 "${profile_sha256}" \
    --arg compatibility_sha256 "${compatibility_sha256}" \
    --arg runtime_sha256 "${runtime_sha256}" \
    --arg runtime_build_id "${runtime_build_id}" '
      .schema_version == 1 and .status == "passed" and
      .canary_tier == "C" and .run == $run and
      .payload_id == $payload_id and
      .payload_fingerprint == $payload_fingerprint and
      .profile_sha256 == $profile_sha256 and
      .compatibility_manifest_sha256 == $compatibility_sha256 and
      .runtime_sha256 == $runtime_sha256 and
      .runtime_build_id == $runtime_build_id and
      (.run_id | type == "string" and
       test("^[0-9]+-[0-9a-f]{40}-[12]-[0-9]+-[0-9]+$")) and
      (.readiness_log_sha256 | test("^[0-9a-f]{64}$"))
    ' "${attestation_path}" >/dev/null
}

PromoteProbationPayload() {
  local -r payload_id="$1"
  [[ "${payload_id}" =~ ^[0-9]+-[0-9a-f]{40}$ ]] ||
    Die "invalid payload ID: ${payload_id}"
  [[ -d "${STORE_ROOT}/payloads/${payload_id}" ]] ||
    Die "payload is not staged: ${payload_id}"
  RequirePayloadIdentity "${payload_id}"
  VerifyPayload "${STORE_ROOT}/payloads/${payload_id}"
  IsSupportedProfile "${payload_id}" &&
    Die "an exact-supported payload must use regular promotion"
  [[ -n "${EXPECTED_PAYLOAD_FINGERPRINT}" &&
     "${EXPECTED_PAYLOAD_FINGERPRINT}" =~ ^[0-9a-f]{64}$ ]] ||
    Die "probation promotion requires --expected-payload-fingerprint"
  [[ "${RUNTIME_FINGERPRINT}" =~ ^[0-9a-f]{64}$ ]] ||
    Die "probation promotion requires a valid --runtime-fingerprint"
  [[ "${RUNTIME_BUILD_ID}" =~ ^[0-9a-f]{40}$ ]] ||
    Die "probation promotion requires a valid --runtime-build-id"
  (( ${#CANARY_ATTESTATION_PATHS[@]} == 2 )) ||
    Die "probation promotion requires exactly two canary attestations"
  IsExactCandidateProfile "${payload_id}" "${CANDIDATE_PROFILE_PATH}" ||
    Die "derived candidate profile is not bound to ${payload_id}"
  IsExactCandidateCompatibility "${payload_id}" \
    "${CANDIDATE_COMPATIBILITY_PATH}" ||
    Die "candidate compatibility manifest is not exact probation metadata"

  local actual_fingerprint profile_sha256 compatibility_sha256
  actual_fingerprint="$(PayloadRuntimeFingerprint "${payload_id}")"
  [[ "${actual_fingerprint}" == "${EXPECTED_PAYLOAD_FINGERPRINT}" ]] ||
    Die "payload ${payload_id} changed after canary"
  profile_sha256="$(sha256sum "${CANDIDATE_PROFILE_PATH}" | awk '{print $1}')"
  compatibility_sha256="$(sha256sum "${CANDIDATE_COMPATIBILITY_PATH}" | awk '{print $1}')"
  VerifyCanaryAttestation "${CANARY_ATTESTATION_PATHS[0]}" 1 \
    "${payload_id}" "${actual_fingerprint}" "${profile_sha256}" \
    "${compatibility_sha256}" "${RUNTIME_FINGERPRINT}" \
    "${RUNTIME_BUILD_ID}" ||
    Die "first canary attestation is invalid"
  VerifyCanaryAttestation "${CANARY_ATTESTATION_PATHS[1]}" 2 \
    "${payload_id}" "${actual_fingerprint}" "${profile_sha256}" \
    "${compatibility_sha256}" "${RUNTIME_FINGERPRINT}" \
    "${RUNTIME_BUILD_ID}" ||
    Die "second canary attestation is invalid"
  [[ "$(jq -er '.run_id' "${CANARY_ATTESTATION_PATHS[0]}")" != \
     "$(jq -er '.run_id' "${CANARY_ATTESTATION_PATHS[1]}")" ]] ||
    Die "canary attestations must have distinct run IDs"
  RequireExpectedCurrent

  local canary_one_sha256 canary_two_sha256
  canary_one_sha256="$(sha256sum "${CANARY_ATTESTATION_PATHS[0]}" | awk '{print $1}')"
  canary_two_sha256="$(sha256sum "${CANARY_ATTESTATION_PATHS[1]}" | awk '{print $1}')"
  local approval_generation
  approval_generation="$(printf '%s\n' \
      "runtime_build_id=${RUNTIME_BUILD_ID}" \
      "payload=${actual_fingerprint}" \
      "profile=${profile_sha256}" \
      "compatibility=${compatibility_sha256}" \
      "canary_1=${canary_one_sha256}" \
      "canary_2=${canary_two_sha256}" |
    sha256sum | awk '{print substr($1, 1, 40)}')"
  CopyApprovalArtifact "${CANDIDATE_PROFILE_PATH}" \
    "$(ApprovedProfilePath "${payload_id}" "${approval_generation}")" \
    "${profile_sha256}"
  CopyApprovalArtifact "${CANDIDATE_COMPATIBILITY_PATH}" \
    "$(ApprovedCompatibilityPath \
      "${payload_id}" "${approval_generation}")" "${compatibility_sha256}"
  CopyApprovalArtifact "${CANARY_ATTESTATION_PATHS[0]}" \
    "$(ApprovedCanaryPath "${payload_id}" "${approval_generation}" 1)" \
    "${canary_one_sha256}"
  CopyApprovalArtifact "${CANARY_ATTESTATION_PATHS[1]}" \
    "$(ApprovedCanaryPath "${payload_id}" "${approval_generation}" 2)" \
    "${canary_two_sha256}"

  local canonical_library libroblox_sha256 receipt_temporary receipt_path
  canonical_library="$(cd -- "${STORE_ROOT}/payloads/${payload_id}" && pwd -P)/libroblox.so"
  libroblox_sha256="$(sha256sum "${canonical_library}" | awk '{print $1}')"
  receipt_path="$(ApprovalReceiptPath \
    "${payload_id}" "${approval_generation}")"
  receipt_temporary="$(mktemp "${STORE_ROOT}/approvals/.receipt.XXXXXX")"
  jq -n \
      --arg payload_id "${payload_id}" \
      --arg generation "${approval_generation}" \
      --arg payload_path "${canonical_library}" \
      --arg build_id "${payload_id#*-}" \
      --arg payload_sha256 "${libroblox_sha256}" \
      --arg payload_fingerprint "${actual_fingerprint}" \
      --arg profile_sha256 "${profile_sha256}" \
      --arg compatibility_sha256 "${compatibility_sha256}" \
      --arg runtime_sha256 "${RUNTIME_FINGERPRINT}" \
      --arg runtime_build_id "${RUNTIME_BUILD_ID}" \
      --arg canary_one_sha256 "${canary_one_sha256}" \
      --arg canary_two_sha256 "${canary_two_sha256}" \
      --arg approved_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
        {schema_version: 1, status: "approved", payload_id: $payload_id,
         generation: $generation,
         payload_path: $payload_path, elf_build_id: $build_id,
         payload_sha256: $payload_sha256,
         payload_fingerprint: $payload_fingerprint,
         profile_sha256: $profile_sha256,
         compatibility_manifest_sha256: $compatibility_sha256,
         canary_runtime_sha256: $runtime_sha256,
         runtime_sha256: $runtime_sha256,
         runtime_build_id: $runtime_build_id, canary_tier: "C",
         successful_runs: 2,
         canary_attestation_sha256:
           [$canary_one_sha256, $canary_two_sha256],
         approved_at: $approved_at}' > "${receipt_temporary}" || {
    rm -f -- "${receipt_temporary}"
    Die "failed to create probation approval receipt"
  }
  chmod 0444 -- "${receipt_temporary}"
  local -r receipt_sha256="$(sha256sum \
    "${receipt_temporary}" | awk '{print $1}')"
  CopyApprovalArtifact "${receipt_temporary}" "${receipt_path}" \
    "${receipt_sha256}"
  rm -f -- "${receipt_temporary}"
  IsApprovedProfile "${payload_id}" "${approval_generation}" ||
    Die "persisted probation approval failed verification"
  PROMOTION_APPROVAL_GENERATION="${approval_generation}"
  PromotePayload "${payload_id}"
}

PromotePayload() {
  local -r payload_id="$1"
  [[ "${payload_id}" =~ ^[0-9]+-[0-9a-f]{40}$ ]] || Die "invalid payload ID: ${payload_id}"
  RequireSupportedProfile "${payload_id}" \
    "${PROMOTION_APPROVAL_GENERATION}"
  if [[ -n "${EXPECTED_PAYLOAD_FINGERPRINT}" ]]; then
    [[ "${EXPECTED_PAYLOAD_FINGERPRINT}" =~ ^[0-9a-f]{64}$ ]] ||
      Die "--expected-payload-fingerprint has an invalid SHA-256 digest"
    local actual_fingerprint
    actual_fingerprint="$(PayloadRuntimeFingerprint "${payload_id}")"
    [[ "${actual_fingerprint}" == "${EXPECTED_PAYLOAD_FINGERPRINT}" ]] ||
      Die "payload ${payload_id} changed after canary"
  fi
  RequireExpectedCurrent

  local current_payload_id
  current_payload_id="$(CurrentPayloadId)"
  if [[ "${current_payload_id}" == "${payload_id}" ]]; then
    WriteManifest "${payload_id}" "${STORE_ROOT}/current.json" \
      "${PROMOTION_APPROVAL_GENERATION}" ||
      Die "failed to refresh the current payload manifest"
    Log "payload is already current: ${payload_id}"
    return 0
  fi
  local previous_backup=""
  local previous_existed=false
  if [[ "${current_payload_id}" != none ]]; then
    if [[ -e "${STORE_ROOT}/previous_good.json" ||
          -L "${STORE_ROOT}/previous_good.json" ]]; then
      ValidateManifestPayload "${STORE_ROOT}/previous_good.json" >/dev/null
      previous_existed=true
      previous_backup="$(mktemp "${STORE_ROOT}/.previous-backup.XXXXXX")"
      cp -- "${STORE_ROOT}/previous_good.json" "${previous_backup}"
    fi
    local previous_temporary
    previous_temporary="$(mktemp "${STORE_ROOT}/.previous-good.XXXXXX")"
    cp -- "${STORE_ROOT}/current.json" "${previous_temporary}"
    if ! mv -f -- "${previous_temporary}" "${STORE_ROOT}/previous_good.json"; then
      rm -f -- "${previous_temporary}"
      [[ -z "${previous_backup}" ]] || rm -f -- "${previous_backup}"
      return 1
    fi
  fi
  if ! WriteManifest "${payload_id}" "${STORE_ROOT}/current.json" \
      "${PROMOTION_APPROVAL_GENERATION}"; then
    if [[ "${previous_existed}" == true ]]; then
      mv -f -- "${previous_backup}" "${STORE_ROOT}/previous_good.json"
    elif [[ "${current_payload_id}" != none ]]; then
      rm -f -- "${STORE_ROOT}/previous_good.json"
    fi
    return 1
  fi
  if [[ -n "${previous_backup}" ]] &&
     ! rm -f -- "${previous_backup}"; then
    Log "warning: failed to remove temporary previous-good backup" || true
  fi
  if IsSupportedProfile "${payload_id}"; then
    Log "promoted supported payload: ${payload_id}" || true
  else
    Log "promoted probation-approved payload: ${payload_id}" || true
  fi
  return 0
}

ImportPayload() {
  local payload_id
  payload_id="$(StagePayload "$1")"
  if IsSupportedProfile "${payload_id}"; then
    PromotePayload "${payload_id}"
  else
    Log "staged ${payload_id} without promotion: Build ID is not default-supported"
  fi
  printf '%s\n' "${payload_id}"
}

RollbackPayload() {
  local -r previous="${STORE_ROOT}/previous_good.json"
  [[ -f "${previous}" ]] || Die "no previous-good payload is available"
  local manifest_identity payload_id approval_generation
  manifest_identity="$(ValidateManifestPayload "${previous}")"
  payload_id="${manifest_identity%%|*}"
  approval_generation="${manifest_identity#*|}"
  if [[ -n "${EXPECTED_ROLLBACK_TARGET}" ]]; then
    [[ "${EXPECTED_ROLLBACK_TARGET}" =~ ^[0-9]+-[0-9a-f]{40}$ ]] ||
      Die "--expected-rollback-target has an invalid payload ID"
    [[ "${payload_id}" == "${EXPECTED_ROLLBACK_TARGET}" ]] ||
      Die "previous-good payload ${payload_id} does not match rollback target ${EXPECTED_ROLLBACK_TARGET}"
  fi
  RequireExpectedCurrent

  if [[ -z "${approval_generation}" ]]; then
    WriteManifest "${payload_id}" "${STORE_ROOT}/current.json" ||
      Die "failed to atomically restore previous-good payload"
    Log "rolled back to previous-good payload: ${payload_id}" || true
    return 0
  fi

  local rollback_temporary
  rollback_temporary="$(mktemp "${STORE_ROOT}/.rollback.XXXXXX")"
  if ! cp -- "${previous}" "${rollback_temporary}" ||
     ! chmod 0644 -- "${rollback_temporary}" ||
     ! ValidateManifestPayload "${rollback_temporary}" >/dev/null ||
     ! mv -f -- "${rollback_temporary}" "${STORE_ROOT}/current.json"; then
    rm -f -- "${rollback_temporary}"
    Die "failed to atomically restore previous-good payload"
  fi
  Log "rolled back to previous-good payload: ${payload_id}" || true
  return 0
}

PrintStatus() {
  jq -n \
    --slurpfile current <(if [[ -f "${STORE_ROOT}/current.json" ]]; then cat "${STORE_ROOT}/current.json"; else printf 'null\n'; fi) \
    --slurpfile previous <(if [[ -f "${STORE_ROOT}/previous_good.json" ]]; then cat "${STORE_ROOT}/previous_good.json"; else printf 'null\n'; fi) \
    '{current: $current[0], previous_good: $previous[0]}'
}

Main() {
  RequireCommands
  ParseGlobalOptions "$@"
  set -- "${REMAINING_ARGUMENTS[@]}"
  (( $# > 0 )) || { Usage >&2; exit 2; }
  local -r command="$1"
  shift
  AcquireStoreLock
  case "${command}" in
    stage)
      (( $# == 1 )) || Die "stage requires PAYLOAD_DIR"
      StagePayload "$1"
      ;;
    import)
      (( $# == 1 )) || Die "import requires PAYLOAD_DIR"
      ImportPayload "$1"
      ;;
    promote)
      (( $# == 1 )) || Die "promote requires PAYLOAD_ID"
      PromotePayload "$1"
      ;;
    promote-probation)
      (( $# == 1 )) || Die "promote-probation requires PAYLOAD_ID"
      PromoteProbationPayload "$1"
      ;;
    fingerprint)
      (( $# == 1 )) || Die "fingerprint requires PAYLOAD_ID"
      [[ "$1" =~ ^[0-9]+-[0-9a-f]{40}$ ]] || Die "invalid payload ID: $1"
      PayloadRuntimeFingerprint "$1"
      ;;
    verify-current)
      (( $# == 0 )) || Die "verify-current accepts no arguments"
      CurrentPayloadId
      ;;
    rollback)
      (( $# == 0 )) || Die "rollback accepts no arguments"
      RollbackPayload
      ;;
    status)
      (( $# == 0 )) || Die "status accepts no arguments"
      PrintStatus
      ;;
    *)
      Die "unknown command: ${command}"
      ;;
  esac
}

Main "$@"

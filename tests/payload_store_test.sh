#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

set -Eeuo pipefail

[[ "$#" == 1 ]] || { echo "usage: $0 /path/to/payload_store.sh" >&2; exit 2; }
STORE_SCRIPT="$1"
TEST_ROOT="$(mktemp -d)"
trap 'chmod -R u+w -- "${TEST_ROOT}" 2>/dev/null || true; rm -rf -- "${TEST_ROOT}"' EXIT
STORE_ROOT="${TEST_ROOT}/store"
COMPATIBILITY_PATH="${TEST_ROOT}/compatibility.json"

AssetTreeHash() {
  local -r assets_root="$1"
  (
    cd -- "${assets_root}"
    while IFS= read -r -d '' relative_path; do
      sha256sum --zero -- "${relative_path}"
    done < <(find -P . -type f -printf '%P\0' | LC_ALL=C sort -z)
  ) | sha256sum | awk '{print $1}'
}

CreatePayload() {
  local -r directory="$1"
  local -r version_code="$2"
  local -r version_name="$3"
  local -r build_id="$4"
  mkdir -p "${directory}/assets" "${directory}/sober_apk"
  printf 'ELF-%s\n' "${build_id}" > "${directory}/libroblox.so"
  printf 'base-%s\n' "${version_code}" > "${directory}/sober_apk/base.apk"
  printf 'split-%s\n' "${version_code}" > "${directory}/sober_apk/split_config.x86_64.apk"
  printf 'asset-%s\n' "${version_code}" > "${directory}/assets/content.bin"
  jq -n \
    --arg version_name "${version_name}" \
    --argjson version_code "${version_code}" \
    --arg build_id "${build_id}" \
    --arg lib_hash "$(sha256sum "${directory}/libroblox.so" | awk '{print $1}')" \
    --arg base_hash "$(sha256sum "${directory}/sober_apk/base.apk" | awk '{print $1}')" \
    --arg split_hash "$(sha256sum "${directory}/sober_apk/split_config.x86_64.apk" | awk '{print $1}')" \
    --arg asset_tree_hash "$(AssetTreeHash "${directory}/assets")" \
    '{schema_version: 1, package: "com.roblox.client", version_name: $version_name,
      version_code: $version_code, abi: "x86_64", elf_build_id: $build_id,
      sha256: {libroblox: $lib_hash, base_apk: $base_hash,
               x86_64_split_apk: $split_hash},
      assets: {file_count: 1, sha256_tree: $asset_tree_hash}}' \
    > "${directory}/roblox_payload.json"
}

RunStore() {
  "${STORE_SCRIPT}" --root "${STORE_ROOT}" \
    --compatibility "${COMPATIBILITY_PATH}" "$@"
}

FIRST_BUILD_ID="1111111111111111111111111111111111111111"
SECOND_BUILD_ID="2222222222222222222222222222222222222222"
THIRD_BUILD_ID="3333333333333333333333333333333333333333"
UNKNOWN_BUILD_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PATCHED_BUILD_ID="4444444444444444444444444444444444444444"
FIRST_ID="100-${FIRST_BUILD_ID}"
SECOND_ID="200-${SECOND_BUILD_ID}"
THIRD_ID="250-${THIRD_BUILD_ID}"
UNKNOWN_ID="300-${UNKNOWN_BUILD_ID}"
PATCHED_ID="400-${PATCHED_BUILD_ID}"

jq -n \
  --arg first "${FIRST_BUILD_ID}" \
  --arg second "${SECOND_BUILD_ID}" \
  --arg third "${THIRD_BUILD_ID}" \
  --arg unverified "${UNKNOWN_BUILD_ID}" \
  --arg patched "${PATCHED_BUILD_ID}" \
  '{schema_version: 1, profiles: [
    {version_name: "1.0", version_code: 100, elf_build_id: $first,
     status: "supported", default_allowed: true,
     allow_legacy_binary_patches: false},
    {version_name: "2.0", version_code: 200, elf_build_id: $second,
     status: "supported", default_allowed: true,
     allow_legacy_binary_patches: false},
    {version_name: "2.5", version_code: 250, elf_build_id: $third,
     status: "supported", default_allowed: true,
     allow_legacy_binary_patches: false},
    {version_name: "3.0", version_code: 300, elf_build_id: $unverified,
     status: "unverified", default_allowed: false,
     allow_legacy_binary_patches: false},
    {version_name: "4.0", version_code: 400, elf_build_id: $patched,
     status: "supported", default_allowed: true,
     allow_legacy_binary_patches: true}
  ]}' > "${COMPATIBILITY_PATH}"

CreatePayload "${TEST_ROOT}/first" 100 1.0 "${FIRST_BUILD_ID}"
CreatePayload "${TEST_ROOT}/second" 200 2.0 "${SECOND_BUILD_ID}"
CreatePayload "${TEST_ROOT}/third" 250 2.5 "${THIRD_BUILD_ID}"
CreatePayload "${TEST_ROOT}/unknown" 300 3.0 "${UNKNOWN_BUILD_ID}"
CreatePayload "${TEST_ROOT}/patched" 400 4.0 "${PATCHED_BUILD_ID}"

mkdir -p "${STORE_ROOT}"
ln -s missing-manifest "${STORE_ROOT}/current.json"
if RunStore import "${TEST_ROOT}/first" >/dev/null 2>&1; then
  echo "a dangling current manifest symlink was treated as no current" >&2
  exit 1
fi
[[ -L "${STORE_ROOT}/current.json" ]]
rm -- "${STORE_ROOT}/current.json"

[[ "$(RunStore import "${TEST_ROOT}/unknown" | tail -n 1)" == "${UNKNOWN_ID}" ]]
[[ -d "${STORE_ROOT}/payloads/${UNKNOWN_ID}" ]]
[[ ! -e "${STORE_ROOT}/current.json" ]] || {
  echo "an unknown Build ID was automatically promoted" >&2
  exit 1
}

[[ "$(RunStore import "${TEST_ROOT}/patched" | tail -n 1)" == "${PATCHED_ID}" ]]
[[ -d "${STORE_ROOT}/payloads/${PATCHED_ID}" ]]
[[ ! -e "${STORE_ROOT}/current.json" ]] || {
  echo "a profile requiring legacy binary patches was promoted" >&2
  exit 1
}

[[ "$(RunStore import "${TEST_ROOT}/first" | tail -n 1)" == "${FIRST_ID}" ]]
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${FIRST_ID}" ]]
[[ ! -e "${STORE_ROOT}/previous_good.json" ]]

# Mutable provenance fields do not turn an identical immutable payload into an
# ID collision when an updater validates the same APK bundle again.
jq '.imported_at = "later"' "${TEST_ROOT}/first/roblox_payload.json" \
  > "${TEST_ROOT}/first/metadata.tmp"
mv "${TEST_ROOT}/first/metadata.tmp" "${TEST_ROOT}/first/roblox_payload.json"
[[ "$(RunStore stage "${TEST_ROOT}/first")" == "${FIRST_ID}" ]]

[[ "$(RunStore stage "${TEST_ROOT}/second")" == "${SECOND_ID}" ]]
if RunStore --expected-current none promote "${SECOND_ID}" >/dev/null 2>&1; then
  echo "promotion ignored a changed current payload" >&2
  exit 1
fi
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${FIRST_ID}" ]]
RunStore --expected-current "${FIRST_ID}" promote "${SECOND_ID}"
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${SECOND_ID}" ]]
[[ "$(jq -r .payload_id "${STORE_ROOT}/previous_good.json")" == "${FIRST_ID}" ]]

RunStore rollback
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${FIRST_ID}" ]]
[[ "$(jq -r .payload_id "${STORE_ROOT}/previous_good.json")" == "${FIRST_ID}" ]]

cp -- "${STORE_ROOT}/previous_good.json" "${TEST_ROOT}/previous.valid.json"
jq '.payload_path = "payloads/../escape"' \
  "${STORE_ROOT}/previous_good.json" \
  > "${STORE_ROOT}/previous.invalid.json"
mv -- "${STORE_ROOT}/previous.invalid.json" \
  "${STORE_ROOT}/previous_good.json"
if RunStore --expected-current "${FIRST_ID}" rollback >/dev/null 2>&1; then
  echo "rollback accepted a non-canonical previous-good manifest" >&2
  exit 1
fi
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${FIRST_ID}" ]]
mv -- "${TEST_ROOT}/previous.valid.json" \
  "${STORE_ROOT}/previous_good.json"

# Keep two distinct valid manifests around the atomic rename boundary so a
# failed current.json replacement must restore the older previous-good bytes.
RunStore --expected-current "${FIRST_ID}" promote "${SECOND_ID}"
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${SECOND_ID}" ]]
[[ "$(jq -r .payload_id "${STORE_ROOT}/previous_good.json")" == "${FIRST_ID}" ]]
[[ "$(RunStore stage "${TEST_ROOT}/third")" == "${THIRD_ID}" ]]

# Promotion must bind the directory name, CLI ID, metadata identity, and the
# exact bytes fingerprinted before canary.
FORGED_ID="999-ffffffffffffffffffffffffffffffffffffffff"
cp -a -- "${STORE_ROOT}/payloads/${THIRD_ID}" \
  "${STORE_ROOT}/payloads/${FORGED_ID}"
if RunStore promote "${FORGED_ID}" >/dev/null 2>&1; then
  echo "promotion accepted a payload directory with mismatched identity" >&2
  exit 1
fi
third_fingerprint="$(RunStore fingerprint "${THIRD_ID}")"
[[ "${third_fingerprint}" =~ ^[0-9a-f]{64}$ ]]
if RunStore --expected-current "${SECOND_ID}" \
    --expected-payload-fingerprint \
      0000000000000000000000000000000000000000000000000000000000000000 \
    promote "${THIRD_ID}" >/dev/null 2>&1; then
  echo "promotion ignored a mismatched pre-canary fingerprint" >&2
  exit 1
fi

# Manifest replacement is performed in two atomic renames. Inject a failure at
# either rename boundary and prove readers still see complete, valid manifests
# for the last working payload rather than a partial promotion.
mkdir -p "${TEST_ROOT}/fail-bin"
REAL_MV="$(command -v mv)"
export REAL_MV
cat > "${TEST_ROOT}/fail-bin/mv" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
destination="${!#}"
if [[ "${destination}" == */"${SIGHTER_TEST_FAIL_MV_DEST}" ]]; then
  exit 73
fi
exec "${REAL_MV}" "$@"
EOF
chmod +x "${TEST_ROOT}/fail-bin/mv"
cp -- "${STORE_ROOT}/current.json" "${TEST_ROOT}/current.before-failed-promotion"
cp -- "${STORE_ROOT}/previous_good.json" \
  "${TEST_ROOT}/previous.before-failed-promotion"
for failed_destination in previous_good.json current.json; do
  set +e
  PATH="${TEST_ROOT}/fail-bin:${PATH}" \
    SIGHTER_TEST_FAIL_MV_DEST="${failed_destination}" \
    RunStore --expected-current "${SECOND_ID}" \
      --expected-payload-fingerprint "${third_fingerprint}" \
      promote "${THIRD_ID}" >/dev/null 2>&1
  promotion_status=$?
  set -e
  [[ "${promotion_status}" -ne 0 ]] || {
    echo "promotion succeeded after ${failed_destination} rename failure" >&2
    exit 1
  }
  cmp --silent "${TEST_ROOT}/current.before-failed-promotion" \
    "${STORE_ROOT}/current.json" || {
    echo "failed promotion changed current.json" >&2
    exit 1
  }
  cmp --silent "${TEST_ROOT}/previous.before-failed-promotion" \
    "${STORE_ROOT}/previous_good.json" || {
    echo "failed promotion changed previous_good.json" >&2
    exit 1
  }
  [[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${SECOND_ID}" ]]
  [[ "$(jq -r .payload_id "${STORE_ROOT}/previous_good.json")" == "${FIRST_ID}" ]]
done

# Rollback uses the same atomic current manifest replacement and can be retried
# safely after an injected rename failure.
set +e
PATH="${TEST_ROOT}/fail-bin:${PATH}" \
  SIGHTER_TEST_FAIL_MV_DEST=current.json \
  RunStore --expected-current "${SECOND_ID}" rollback >/dev/null 2>&1
rollback_status=$?
set -e
[[ "${rollback_status}" -ne 0 ]]
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${SECOND_ID}" ]]
[[ "$(jq -r .payload_id "${STORE_ROOT}/previous_good.json")" == "${FIRST_ID}" ]]
if RunStore --expected-current "${SECOND_ID}" \
    --expected-rollback-target "${THIRD_ID}" rollback >/dev/null 2>&1; then
  echo "rollback ignored its expected previous-good target" >&2
  exit 1
fi
RunStore --expected-current "${SECOND_ID}" \
  --expected-rollback-target "${FIRST_ID}" rollback
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${FIRST_ID}" ]]
[[ "$(jq -r .payload_id "${STORE_ROOT}/previous_good.json")" == "${FIRST_ID}" ]]

# Promotion revalidates immutable bytes under the store lock, after the
# external canary has returned. A candidate modified in that interval is
# quarantined on restage and never becomes current.
chmod u+w "${STORE_ROOT}/payloads/${SECOND_ID}" \
  "${STORE_ROOT}/payloads/${SECOND_ID}/libroblox.so"
printf 'post-canary corruption\n' \
  >> "${STORE_ROOT}/payloads/${SECOND_ID}/libroblox.so"
if RunStore --expected-current "${FIRST_ID}" promote "${SECOND_ID}" \
    >/dev/null 2>&1; then
  echo "corrupt staged candidate was promoted" >&2
  exit 1
fi
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${FIRST_ID}" ]]
[[ "$(RunStore stage "${TEST_ROOT}/second")" == "${SECOND_ID}" ]]
find "${STORE_ROOT}/quarantine" -mindepth 1 -maxdepth 1 \
  -name "${SECOND_ID}-*" -print -quit | grep -q . || {
  echo "corrupt candidate was not quarantined during recovery" >&2
  exit 1
}

chmod u+w "${STORE_ROOT}/payloads/${SECOND_ID}" \
  "${STORE_ROOT}/payloads/${SECOND_ID}/assets/content.bin"
printf 'post-canary asset corruption\n' \
  >> "${STORE_ROOT}/payloads/${SECOND_ID}/assets/content.bin"
if RunStore --expected-current "${FIRST_ID}" promote "${SECOND_ID}" \
    >/dev/null 2>&1; then
  echo "candidate with changed asset bytes was promoted" >&2
  exit 1
fi
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${FIRST_ID}" ]]
[[ "$(RunStore stage "${TEST_ROOT}/second")" == "${SECOND_ID}" ]]

permissions="$(stat -c '%A' "${STORE_ROOT}/payloads/${FIRST_ID}/libroblox.so")"
[[ "${permissions}" != *w* ]] || {
  echo "staged payload remains writable: ${permissions}" >&2
  exit 1
}

chmod u+w "${STORE_ROOT}/payloads/${FIRST_ID}"
rm -- "${STORE_ROOT}/payloads/${FIRST_ID}/libroblox.so"
[[ "$(RunStore stage "${TEST_ROOT}/first")" == "${FIRST_ID}" ]]
[[ -f "${STORE_ROOT}/payloads/${FIRST_ID}/libroblox.so" ]]
find "${STORE_ROOT}/quarantine" -mindepth 1 -maxdepth 1 \
  -name "${FIRST_ID}-*" -print -quit | grep -q . || {
  echo "corrupt immutable payload was not quarantined" >&2
  exit 1
}

printf 'corrupt\n' >> "${TEST_ROOT}/unknown/libroblox.so"
if RunStore stage "${TEST_ROOT}/unknown" >/dev/null 2>&1; then
  echo "payload with a mismatched hash was accepted" >&2
  exit 1
fi

if RunStore promote "${UNKNOWN_ID}" >/dev/null 2>&1; then
  echo "an unknown Build ID was explicitly promoted without a profile" >&2
  exit 1
fi

# verify-current validates supported payload bytes, not only current.json.
[[ "$(RunStore verify-current)" == "${FIRST_ID}" ]]
chmod u+w -- "${STORE_ROOT}/payloads/${FIRST_ID}/libroblox.so"
printf 'tampered\n' >> "${STORE_ROOT}/payloads/${FIRST_ID}/libroblox.so"
if RunStore verify-current >/dev/null 2>&1; then
  echo "verify-current accepted modified supported payload bytes" >&2
  exit 1
fi
cp -- "${TEST_ROOT}/first/libroblox.so" \
  "${STORE_ROOT}/payloads/${FIRST_ID}/libroblox.so"
chmod a-w -- "${STORE_ROOT}/payloads/${FIRST_ID}/libroblox.so"
[[ "$(RunStore verify-current)" == "${FIRST_ID}" ]]

# A non-shipped Build ID crosses the activation boundary only with an exact
# derived profile, an isolated candidate manifest, and two distinct Tier C
# attestations bound to the same payload/profile/runtime bytes.
unknown_fingerprint="$(RunStore fingerprint "${UNKNOWN_ID}")"
unknown_payload_sha256="$(sha256sum \
  "${STORE_ROOT}/payloads/${UNKNOWN_ID}/libroblox.so" | awk '{print $1}')"
candidate_profile="${TEST_ROOT}/candidate-profile.json"
candidate_compatibility="${TEST_ROOT}/candidate-compatibility.json"
runtime_sha256=5555555555555555555555555555555555555555555555555555555555555555
runtime_build_id=6666666666666666666666666666666666666666
jq -n --arg payload_id "${UNKNOWN_ID}" \
  --arg payload_path "payloads/${UNKNOWN_ID}" \
  --arg build_id "${UNKNOWN_BUILD_ID}" \
  --arg payload_sha256 "${unknown_payload_sha256}" '
  {schema_version:1,payload_id:$payload_id,payload_path:$payload_path,
   elf_build_id:$build_id,payload_sha256:$payload_sha256,
   reference:{elf_build_id:"1111111111111111111111111111111111111111",
              payload_sha256:"7777777777777777777777777777777777777777777777777777777777777777"},
   profile:{bridge_entries:[],data_seeds:{},native_allocator:{},
     constructor_run_ranges:[{begin:2,end_exclusive:3}],
     native_mimalloc_constructor_run_ranges:[{begin:2,end_exclusive:3}],
     native_pre_jni_bootstrap:{},default_allocator_strategy:"native_mimalloc"}}
' > "${candidate_profile}"
jq -n --arg build_id "${UNKNOWN_BUILD_ID}" '
  {schema_version:1,profiles:[{version_name:"3.0",version_code:300,
   elf_build_id:$build_id,status:"experimental",default_allowed:true,
   allow_legacy_binary_patches:false,allow_host_abi_bridges:true,
   allow_host_constructor_replay:true}]}
' > "${candidate_compatibility}"
profile_sha256="$(sha256sum "${candidate_profile}" | awk '{print $1}')"
compatibility_sha256="$(sha256sum "${candidate_compatibility}" | awk '{print $1}')"
CreateAttestation() {
  local -r run="$1"
  local -r output="$2"
  jq -n --argjson run "${run}" \
    --arg run_id "${UNKNOWN_ID}-${run}-123456789${run}-99" \
    --arg payload_id "${UNKNOWN_ID}" \
    --arg payload_fingerprint "${unknown_fingerprint}" \
    --arg profile_sha256 "${profile_sha256}" \
    --arg compatibility_sha256 "${compatibility_sha256}" \
    --arg runtime_sha256 "${runtime_sha256}" \
    --arg runtime_build_id "${runtime_build_id}" \
    '{schema_version:1,status:"passed",canary_tier:"C",run:$run,
      run_id:$run_id,payload_id:$payload_id,
      payload_fingerprint:$payload_fingerprint,
      profile_sha256:$profile_sha256,
      compatibility_manifest_sha256:$compatibility_sha256,
      runtime_sha256:$runtime_sha256,runtime_build_id:$runtime_build_id,
      readiness_log_sha256:
        "8888888888888888888888888888888888888888888888888888888888888888"}' \
    > "${output}"
}
CreateAttestation 1 "${TEST_ROOT}/canary-1.json"
CreateAttestation 2 "${TEST_ROOT}/canary-2.json"

probation_arguments=(
  --expected-current "${FIRST_ID}"
  --expected-payload-fingerprint "${unknown_fingerprint}"
  --candidate-profile "${candidate_profile}"
  --candidate-compatibility "${candidate_compatibility}"
  --runtime-fingerprint "${runtime_sha256}"
  --runtime-build-id "${runtime_build_id}"
  --canary-attestation "${TEST_ROOT}/canary-1.json"
)
if RunStore "${probation_arguments[@]}" promote-probation "${UNKNOWN_ID}" \
    >/dev/null 2>&1; then
  echo "probation promotion accepted only one canary run" >&2
  exit 1
fi
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${FIRST_ID}" ]]

probation_arguments+=(--canary-attestation "${TEST_ROOT}/canary-2.json")
cp -- "${candidate_profile}" "${TEST_ROOT}/candidate-profile.valid.json"
jq '.profile.init_array_count = 99' "${candidate_profile}" \
  > "${TEST_ROOT}/candidate-profile.changed.json"
mv -- "${TEST_ROOT}/candidate-profile.changed.json" "${candidate_profile}"
if RunStore "${probation_arguments[@]}" promote-probation "${UNKNOWN_ID}" \
    >/dev/null 2>&1; then
  echo "probation promotion ignored a post-canary profile change" >&2
  exit 1
fi
mv -- "${TEST_ROOT}/candidate-profile.valid.json" "${candidate_profile}"
RunStore "${probation_arguments[@]}" promote-probation "${UNKNOWN_ID}"
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${UNKNOWN_ID}" ]]
[[ "$(jq -r .payload_id "${STORE_ROOT}/previous_good.json")" == "${FIRST_ID}" ]]
first_approval_ref="$(jq -r .approval_path "${STORE_ROOT}/current.json")"
[[ "${first_approval_ref}" =~ ^approvals/${UNKNOWN_ID}-[0-9a-f]{40}\.json$ ]]
first_generation="${first_approval_ref#approvals/${UNKNOWN_ID}-}"
first_generation="${first_generation%.json}"
[[ "$(jq -r .host_abi_profile_path "${STORE_ROOT}/current.json")" == \
  "host_abi_profiles/${UNKNOWN_ID}-${first_generation}.json" ]]
[[ "$(jq -r .compatibility_manifest_path "${STORE_ROOT}/current.json")" == \
  "compatibility_profiles/${UNKNOWN_ID}-${first_generation}.json" ]]
[[ "$(jq -r .successful_runs "${STORE_ROOT}/${first_approval_ref}")" == 2 ]]
[[ -f "${STORE_ROOT}/approvals/${UNKNOWN_ID}-${first_generation}.canary-1.json" ]]
[[ -f "${STORE_ROOT}/approvals/${UNKNOWN_ID}-${first_generation}.canary-2.json" ]]
[[ "$(RunStore verify-current)" == "${UNKNOWN_ID}" ]]

# Renaming an internally self-consistent evidence set and editing only the
# receipt generation cannot forge the generation digest.
forged_generation=abababababababababababababababababababab
cp -- "${STORE_ROOT}/host_abi_profiles/${UNKNOWN_ID}-${first_generation}.json" \
  "${STORE_ROOT}/host_abi_profiles/${UNKNOWN_ID}-${forged_generation}.json"
cp -- "${STORE_ROOT}/compatibility_profiles/${UNKNOWN_ID}-${first_generation}.json" \
  "${STORE_ROOT}/compatibility_profiles/${UNKNOWN_ID}-${forged_generation}.json"
cp -- "${STORE_ROOT}/approvals/${UNKNOWN_ID}-${first_generation}.canary-1.json" \
  "${STORE_ROOT}/approvals/${UNKNOWN_ID}-${forged_generation}.canary-1.json"
cp -- "${STORE_ROOT}/approvals/${UNKNOWN_ID}-${first_generation}.canary-2.json" \
  "${STORE_ROOT}/approvals/${UNKNOWN_ID}-${forged_generation}.canary-2.json"
jq --arg generation "${forged_generation}" '.generation = $generation' \
  "${STORE_ROOT}/${first_approval_ref}" \
  > "${STORE_ROOT}/approvals/${UNKNOWN_ID}-${forged_generation}.json"
cp -- "${STORE_ROOT}/current.json" "${TEST_ROOT}/current.before-forgery.json"
jq --arg approval "approvals/${UNKNOWN_ID}-${forged_generation}.json" \
  --arg profile "host_abi_profiles/${UNKNOWN_ID}-${forged_generation}.json" \
  --arg compatibility \
    "compatibility_profiles/${UNKNOWN_ID}-${forged_generation}.json" \
  '.approval_path = $approval | .host_abi_profile_path = $profile |
   .compatibility_manifest_path = $compatibility' \
  "${STORE_ROOT}/current.json" > "${TEST_ROOT}/current.forged.json"
mv -- "${TEST_ROOT}/current.forged.json" "${STORE_ROOT}/current.json"
if RunStore verify-current >/dev/null 2>&1; then
  echo "verify-current accepted a forged evidence generation" >&2
  exit 1
fi
mv -- "${TEST_ROOT}/current.before-forgery.json" "${STORE_ROOT}/current.json"

# Cross-generation refs and receipt corruption must fail closed.
cp -- "${STORE_ROOT}/current.json" "${TEST_ROOT}/current.valid.json"
jq --arg path "host_abi_profiles/${UNKNOWN_ID}-$(printf '9%.0s' {1..40}).json" \
  '.host_abi_profile_path = $path' "${STORE_ROOT}/current.json" \
  > "${TEST_ROOT}/current.mismatched.json"
mv -- "${TEST_ROOT}/current.mismatched.json" "${STORE_ROOT}/current.json"
if RunStore verify-current >/dev/null 2>&1; then
  echo "verify-current accepted cross-generation approval references" >&2
  exit 1
fi
mv -- "${TEST_ROOT}/current.valid.json" "${STORE_ROOT}/current.json"
cp -- "${STORE_ROOT}/${first_approval_ref}" "${TEST_ROOT}/receipt.valid.json"
chmod u+w -- "${STORE_ROOT}/${first_approval_ref}"
jq '.payload_fingerprint = ("0" * 64)' \
  "${STORE_ROOT}/${first_approval_ref}" > "${TEST_ROOT}/receipt.tampered.json"
mv -- "${TEST_ROOT}/receipt.tampered.json" \
  "${STORE_ROOT}/${first_approval_ref}"
if RunStore verify-current >/dev/null 2>&1; then
  echo "verify-current accepted a tampered approval receipt" >&2
  exit 1
fi
cp -- "${TEST_ROOT}/receipt.valid.json" "${STORE_ROOT}/${first_approval_ref}"
chmod 0444 -- "${STORE_ROOT}/${first_approval_ref}"

# Reapproval for a new runtime creates a new immutable evidence generation,
# atomically switches only current.json, and leaves previous_good unchanged.
cp -- "${STORE_ROOT}/previous_good.json" "${TEST_ROOT}/previous.before-reapproval"
runtime_sha256=9999999999999999999999999999999999999999999999999999999999999999
runtime_build_id=7777777777777777777777777777777777777777
CreateAttestation 1 "${TEST_ROOT}/canary-new-1.json"
CreateAttestation 2 "${TEST_ROOT}/canary-new-2.json"
reapproval_arguments=(
  --expected-current "${UNKNOWN_ID}"
  --expected-payload-fingerprint "${unknown_fingerprint}"
  --candidate-profile "${candidate_profile}"
  --candidate-compatibility "${candidate_compatibility}"
  --runtime-fingerprint "${runtime_sha256}"
  --runtime-build-id "${runtime_build_id}"
  --canary-attestation "${TEST_ROOT}/canary-new-1.json"
  --canary-attestation "${TEST_ROOT}/canary-new-2.json"
)
RunStore "${reapproval_arguments[@]}" promote-probation "${UNKNOWN_ID}"
second_approval_ref="$(jq -r .approval_path "${STORE_ROOT}/current.json")"
[[ "${second_approval_ref}" =~ ^approvals/${UNKNOWN_ID}-[0-9a-f]{40}\.json$ ]]
[[ "${second_approval_ref}" != "${first_approval_ref}" ]]
[[ -f "${STORE_ROOT}/${first_approval_ref}" &&
   -f "${STORE_ROOT}/${second_approval_ref}" ]]
[[ "$(jq -r .runtime_build_id "${STORE_ROOT}/${second_approval_ref}")" == \
  "${runtime_build_id}" ]]
cmp --silent "${TEST_ROOT}/previous.before-reapproval" \
  "${STORE_ROOT}/previous_good.json"

# A later rollback to dynamic previous_good preserves its exact generation.
RunStore --expected-current "${UNKNOWN_ID}" promote "${SECOND_ID}"
[[ "$(jq -r .approval_path "${STORE_ROOT}/previous_good.json")" == \
  "${second_approval_ref}" ]]
RunStore --expected-current "${SECOND_ID}" \
  --expected-rollback-target "${UNKNOWN_ID}" rollback
[[ "$(jq -r .approval_path "${STORE_ROOT}/current.json")" == \
  "${second_approval_ref}" ]]
[[ "$(RunStore verify-current)" == "${UNKNOWN_ID}" ]]
RunStore --expected-current "${UNKNOWN_ID}" promote "${FIRST_ID}"

# Once the same exact Build ID ships as a built-in supported profile, a newly
# written manifest must stop carrying stale dynamic approval references.
jq '(.profiles[] | select(.version_code == 300)) |=
      (.status = "supported" | .default_allowed = true)' \
  "${COMPATIBILITY_PATH}" > "${TEST_ROOT}/compatibility.promoted.json"
mv -- "${TEST_ROOT}/compatibility.promoted.json" "${COMPATIBILITY_PATH}"
RunStore --expected-current "${FIRST_ID}" promote "${UNKNOWN_ID}"
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${UNKNOWN_ID}" ]]
[[ "$(jq -r 'has("approval_path")' "${STORE_ROOT}/current.json")" == false ]]
RunStore --expected-current "${UNKNOWN_ID}" \
  --expected-rollback-target "${FIRST_ID}" rollback
[[ "$(jq -r .payload_id "${STORE_ROOT}/current.json")" == "${FIRST_ID}" ]]

status="$(RunStore status)"
[[ "$(jq -r .current.payload_id <<<"${status}")" == "${FIRST_ID}" ]]
[[ "$(jq -r .previous_good.payload_id <<<"${status}")" == "${FIRST_ID}" ]]

echo "payload store staging, promotion, and rollback checks passed"

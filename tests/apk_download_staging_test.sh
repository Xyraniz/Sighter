#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

set -Eeuo pipefail

FETCH_SCRIPT="${1:?fetch script path is required}"
TEMP_DIR="$(mktemp -d)"
cleanup() {
  chmod -R u+w "${TEMP_DIR}" 2>/dev/null || true
  rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT
mkdir -p "${TEMP_DIR}/bin"

cat > "${TEMP_DIR}/bin/aapt" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
apk="${3:?APK path is required}"
metadata="$(unzip -p "${apk}" sighter-test-metadata)"
IFS='|' read -r kind version_code version_name <<< "${metadata}"
if [[ "${kind}" == base ]]; then
  printf "package: name='com.roblox.client' versionCode='%s' versionName='%s'\n" \
    "${version_code}" "${version_name}"
else
  printf "package: name='com.roblox.client' versionCode='%s' versionName='%s' split='%s'\n" \
    "${version_code}" "${version_name}" "${kind}"
fi
EOF

cat > "${TEMP_DIR}/bin/provider" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
arguments="$*"
output=""
while (( $# > 0 )); do
  if [[ "$1" == --output ]]; then output="$2"; shift 2; else shift; fi
done
mkdir -p "${output}" "${output}/content/lib/x86_64"
printf '%s\n' "${arguments}" > "${FAKE_PROVIDER_ARGUMENTS}"

make_apk() {
  local destination="$1" metadata="$2" include_library="$3"
  local work
  work="$(mktemp -d)"
  printf '%s' "${metadata}" > "${work}/sighter-test-metadata"
  if [[ "${include_library}" == true ]]; then
    mkdir -p "${work}/lib/x86_64"
    printf 'test ELF bytes' > "${work}/lib/x86_64/libroblox.so"
  fi
  find "${work}" -exec touch -t 200001010000 {} +
  (cd "${work}" && zip -X -q -r "${destination}" .)
  rm -rf -- "${work}"
}

make_apk "${output}/base.apk" 'base|2547|2.726.1000' false
case "${FAKE_PROVIDER_MODE:-direct}" in
  direct)
    make_apk "${output}/split_config.x86_64.apk" \
      'config.x86_64|2547|2.726.1000' true
    ;;
  missing-x86)
    make_apk "${output}/split_config.arm64_v8a.apk" \
      'config.arm64_v8a|2547|2.726.1000' false
    ;;
  mismatched)
    make_apk "${output}/split_config.x86_64.apk" \
      'config.x86_64|2548|2.727.1000' true
    ;;
  bundle)
    make_apk "${output}/split_config.x86_64.apk" \
      'config.x86_64|2547|' true
    (cd "${output}" && zip -X -q roblox.xapk base.apk split_config.x86_64.apk)
    rm -- "${output}/base.apk" "${output}/split_config.x86_64.apk"
    ;;
  monolithic)
    rm -- "${output}/base.apk"
    make_apk "${output}/roblox.apk" 'base|2547|2.726.1000' true
    ;;
esac
EOF
chmod +x "${TEMP_DIR}/bin/aapt" "${TEMP_DIR}/bin/provider"

export PATH="${TEMP_DIR}/bin:${PATH}"
export SIGHTER_APK_PROVIDER_COMMAND="${TEMP_DIR}/bin/provider"
export FAKE_PROVIDER_ARGUMENTS="${TEMP_DIR}/provider-arguments"
export FAKE_PROVIDER_MODE=direct
staging_root="${TEMP_DIR}/staging-success"
active_sentinel="${TEMP_DIR}/active-payload"
printf 'must remain unchanged' > "${active_sentinel}"

bundle="$(${FETCH_SCRIPT} --source apk-pure --staging-root "${staging_root}")"
[[ -d "${bundle}" ]] || { echo "fetch did not publish a staged bundle" >&2; exit 1; }
[[ "${bundle}" == "${staging_root}/com.roblox.client-2547-"* ]] || {
  echo "unexpected staged bundle name: ${bundle}" >&2
  exit 1
}
[[ -f "${bundle}/base.apk" && -f "${bundle}/split_config.x86_64.apk" ]] || {
  echo "staged APK pair is incomplete" >&2
  exit 1
}
jq -e '
  .state == "downloaded" and .activated == false and
  .package == "com.roblox.client" and .version_code == 2547 and
  .abi == "x86_64" and .provider == "direct_apkpure" and
  .files.base == "base.apk" and
  .files.x86_64_split == "split_config.x86_64.apk"
' "${bundle}/download.json" >/dev/null
[[ ! -w "${bundle}/download.json" ]] || {
  echo "published bundle must be immutable" >&2
  exit 1
}
[[ "$(cat "${active_sentinel}")" == 'must remain unchanged' ]] || {
  echo "fetch changed active payload state" >&2
  exit 1
}
grep -Fq -- '--package com.roblox.client' "${FAKE_PROVIDER_ARGUMENTS}"
grep -Fq -- '--source apk-pure' "${FAKE_PROVIDER_ARGUMENTS}"

bundle_again="$(${FETCH_SCRIPT} --source apk-pure --staging-root "${staging_root}")"
[[ "${bundle_again}" == "${bundle}" ]] || {
  echo "idempotent fetch selected a different bundle" >&2
  exit 1
}

export FAKE_PROVIDER_MODE=bundle
bundle_from_xapk="$(${FETCH_SCRIPT} --staging-root "${TEMP_DIR}/staging-xapk")"
[[ -f "${bundle_from_xapk}/base.apk" &&
   -f "${bundle_from_xapk}/split_config.x86_64.apk" ]] || {
  echo "XAPK provider output was not normalized" >&2
  exit 1
}
[[ "${bundle_from_xapk}" =~ -[0-9a-f]{12}-[0-9a-f]{12}$ ]] || {
  echo "split without versionName corrupted the staged bundle ID" >&2
  exit 1
}

export FAKE_PROVIDER_MODE=monolithic
bundle_monolithic="$(${FETCH_SCRIPT} --staging-root "${TEMP_DIR}/staging-monolithic")"
cmp "${bundle_monolithic}/base.apk" "${bundle_monolithic}/split_config.x86_64.apk"

export FAKE_PROVIDER_MODE=direct
if "${FETCH_SCRIPT}" --version 9.9.9 \
    --staging-root "${TEMP_DIR}/staging-wrong-version" >/dev/null 2>&1; then
  echo "provider response ignored the requested version" >&2
  exit 1
fi

export FAKE_PROVIDER_MODE=missing-x86
if "${FETCH_SCRIPT}" --staging-root "${TEMP_DIR}/staging-missing" >"${TEMP_DIR}/missing.out" 2>&1; then
  echo "ARM-only provider output unexpectedly succeeded" >&2
  exit 1
fi
find "${TEMP_DIR}/staging-missing" -mindepth 1 -maxdepth 1 ! -name '.fetch.*' -print -quit |
  grep -q . && { echo "failed fetch published a bundle" >&2; exit 1; }

export FAKE_PROVIDER_MODE=mismatched
if "${FETCH_SCRIPT}" --staging-root "${TEMP_DIR}/staging-mismatch" >"${TEMP_DIR}/mismatch.out" 2>&1; then
  echo "mismatched base/split versions unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq 'no matching Roblox base and config.x86_64 APK pair found' "${TEMP_DIR}/mismatch.out"

printf 'APK download staging test passed\n'

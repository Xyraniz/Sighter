#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

readonly ROOT="${1:?source root is required}"
readonly TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_DIR}"' EXIT

Fail() {
  printf 'managed payload build contract test failed: %s\n' "$*" >&2
  exit 1
}

NormalizeDryRun() {
  tr -d '"'
}

build_route="$(
  make -C "${ROOT}" --no-print-directory --dry-run build JOBS=2 |
    NormalizeDryRun
)"
grep -Fq 'git submodule update --init --recursive' <<<"${build_route}" ||
  Fail 'make build does not initialize pinned source dependencies'
grep -Fq 'cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF' \
  <<<"${build_route}" || Fail 'make build does not configure dynamic Release'
grep -Fq 'cmake --build build -j2' <<<"${build_route}" ||
  Fail 'make build does not invoke the native CMake build'
if grep -Eq 'build\.sh|build_release\.sh|appimagetool|--apk([[:space:]]|$)' \
    <<<"${build_route}"; then
  Fail 'make build still proxies through packaging or APK scripts'
fi

default_route="$(
  make -C "${ROOT}" --no-print-directory --dry-run JOBS=2 |
    NormalizeDryRun
)"
grep -Fq 'cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF' \
  <<<"${default_route}" || Fail 'plain make is not an alias for make build'

release_route="$(
  make -C "${ROOT}" --no-print-directory --dry-run release \
    JOBS=3 LIBC=glibc MODE=standalone |
    NormalizeDryRun
)"
grep -Fq './scripts/build_release.sh --libc glibc --mode standalone' \
  <<<"${release_route}" || Fail 'make release lost the packaged release route'

portable_route="$(
  make -C "${ROOT}" --no-print-directory --dry-run portable JOBS=2 |
    NormalizeDryRun
)"
grep -Fq './scripts/package_portable.sh' <<<"${portable_route}" ||
  Fail 'make portable no longer invokes the portable packager'
grep -Fq -- '--appimage dist/Sighter-x86_64.AppImage' \
  <<<"${portable_route}" || Fail 'make portable no longer publishes an AppImage'

run_route="$(
  make -C "${ROOT}" --no-print-directory --dry-run run JOBS=2 |
    NormalizeDryRun
)"
grep -Fxq 'build/sighter' <<<"${run_route}" ||
  Fail 'make run does not execute the native binary directly'
if grep -Fq 'real_bringup_smoke.sh' <<<"${run_route}"; then
  Fail 'make run still proxies the normal launch through a readiness script'
fi

mkdir -p -- "${TEMP_DIR}/bin" "${TEMP_DIR}/home"
readonly TOOL_LOG="${TEMP_DIR}/tool.log"
readonly FORBIDDEN_TOOL_LOG="${TEMP_DIR}/forbidden-tool.log"

cat >"${TEMP_DIR}/bin/cmake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cmake' >>"${SIGHTER_TEST_TOOL_LOG}"
printf ' %q' "$@" >>"${SIGHTER_TEST_TOOL_LOG}"
printf '\n' >>"${SIGHTER_TEST_TOOL_LOG}"
exit 0
EOF

cat >"${TEMP_DIR}/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git' >>"${SIGHTER_TEST_TOOL_LOG}"
printf ' %q' "$@" >>"${SIGHTER_TEST_TOOL_LOG}"
printf '\n' >>"${SIGHTER_TEST_TOOL_LOG}"
exit 0
EOF

for tool in unzip curl wget; do
  cat >"${TEMP_DIR}/bin/${tool}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${0##*/}" >>"${SIGHTER_TEST_FORBIDDEN_TOOL_LOG}"
exit 91
EOF
done
chmod +x -- "${TEMP_DIR}/bin/"*

RunManagedMake() {
  local build_dir="$1"
  env -u ROBLOX_LIB_PATH \
    HOME="${TEMP_DIR}/home" \
    PATH="${TEMP_DIR}/bin:/usr/bin:/bin" \
    SIGHTER_TEST_TOOL_LOG="${TOOL_LOG}" \
    SIGHTER_TEST_FORBIDDEN_TOOL_LOG="${FORBIDDEN_TOOL_LOG}" \
    make -C "${ROOT}" --no-print-directory build \
      BUILD_DIR="${build_dir}" JOBS=1
}

RunManagedMake "${TEMP_DIR}/managed-build"
[[ ! -e "${FORBIDDEN_TOOL_LOG}" ]] ||
  Fail 'default managed build invoked an APK download or extraction tool'
grep -Fq 'git submodule update --init --recursive' "${TOOL_LOG}" ||
  Fail 'default build did not initialize pinned source submodules'
grep -Fq "cmake -S . -B ${TEMP_DIR}/managed-build" "${TOOL_LOG}" ||
  Fail 'default build did not configure the requested CMake directory'
grep -Fq "cmake --build ${TEMP_DIR}/managed-build -j1" "${TOOL_LOG}" ||
  Fail 'default build did not compile the configured CMake directory'

apk_route="$(
  make -C "${ROOT}" --no-print-directory --dry-run apk \
    APK="${TEMP_DIR}/explicit.apk" JOBS=1 |
    NormalizeDryRun
)"
grep -Fq './scripts/build.sh --apk' <<<"${apk_route}" ||
  Fail 'explicit research APK import is not isolated behind make apk'

printf 'managed payload build contract test passed\n'

#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

readonly ROOT="$1"
readonly BUILD_DIR="$2"
readonly BUILDER="${ROOT}/scripts/build_release.sh"
readonly PACKAGER="${ROOT}/scripts/package_portable.sh"
readonly ABI_VERIFIER="${ROOT}/scripts/verify_linux_libc_abi.sh"

Fail() {
  printf 'release build contract test failed: %s\n' "$*" >&2
  exit 1
}

ExpectRejected() {
  local description="$1"
  shift
  local output
  if output="$("${BUILDER}" "$@" 2>&1)"; then
    Fail "${description} was accepted"
  fi
  grep -Fq -- "$description" <<<"${output}" ||
    Fail "${description} did not produce the expected diagnostic"
}

NormalizeDryRun() {
  tr -d '"'
}

bash -n \
  "${BUILDER}" \
  "${PACKAGER}" \
  "${ROOT}/scripts/verify_linux_libc_abi.sh"

grep -Fq -- '--appimage "${appimage}"' "${BUILDER}" ||
  Fail 'release builder does not publish an AppImage'
if grep -Fq -- '--tarball "${tarball}"' "${BUILDER}"; then
  Fail 'release builder still publishes a tarball'
fi
if grep -Fq -- '--tarball' "${PACKAGER}"; then
  Fail 'portable packager still exposes a tarball output'
fi

grep -Eq '^\.PHONY:.*(^|[[:space:]])build([[:space:]]|$)' \
  "${ROOT}/Makefile" || Fail 'build target is not phony'
grep -Eq '^\.PHONY:.*(^|[[:space:]])release([[:space:]]|$)' \
  "${ROOT}/Makefile" || Fail 'release target is not phony'
grep -Eq '^\.PHONY:.*(^|[[:space:]])install([[:space:]]|$)' \
  "${ROOT}/Makefile" || Fail 'install target is not phony'

install_route="$(
  make -C "${ROOT}" --no-print-directory --dry-run install PREFIX=/usr |
    NormalizeDryRun
)"
grep -Fq 'cmake --install build --prefix /usr' <<<"${install_route}" ||
  Fail 'install target does not route through CMake with PREFIX'

default_route="$(
  make -C "${ROOT}" --no-print-directory --dry-run release JOBS=2 |
    NormalizeDryRun
)"
grep -Fq 'SIGHTER_BUILD_JOBS=2' <<<"${default_route}" ||
  Fail 'default release route did not forward JOBS'
grep -Fq './scripts/build_release.sh --libc auto --mode standalone' \
  <<<"${default_route}" ||
  Fail 'default release route is not auto/standalone'

glibc_standalone_route="$(
  make -C "${ROOT}" --no-print-directory --dry-run release \
    JOBS=3 LIBC=glibc MODE=standalone |
    NormalizeDryRun
)"
grep -Fq 'SIGHTER_BUILD_JOBS=3' <<<"${glibc_standalone_route}" ||
  Fail 'glibc/standalone route did not forward JOBS'
grep -Fq './scripts/build_release.sh --libc glibc --mode standalone' \
  <<<"${glibc_standalone_route}" ||
  Fail 'glibc/standalone route is incorrect'

for alias in full static dynamic minimal; do
  alias_route="$(
    make -C "${ROOT}" --no-print-directory --dry-run release \
      JOBS=1 LIBC=glibc MODE="${alias}" |
      NormalizeDryRun
  )"
  grep -Fq "./scripts/build_release.sh --libc glibc --mode ${alias}" \
    <<<"${alias_route}" ||
    Fail "${alias} alias was not forwarded to the release builder"
done

readonly fake_toolchain='/tmp/sighter-musl-x86_64.cmake'
musl_thin_route="$(
  make -C "${ROOT}" --no-print-directory --dry-run release \
    JOBS=4 LIBC=musl MODE=thin CMAKE_TOOLCHAIN_FILE="${fake_toolchain}" |
    NormalizeDryRun
)"
grep -Fq 'SIGHTER_BUILD_JOBS=4' <<<"${musl_thin_route}" ||
  Fail 'musl/thin route did not forward JOBS'
grep -Fq './scripts/build_release.sh --libc musl --mode thin' \
  <<<"${musl_thin_route}" ||
  Fail 'musl/thin route is incorrect'
grep -Fq "${fake_toolchain}" <<<"${musl_thin_route}" ||
  Fail 'musl/thin route did not forward CMAKE_TOOLCHAIN_FILE'

ExpectRejected '--libc must be auto, glibc, or musl' \
  --libc invalid --mode standalone
ExpectRejected '--mode must be standalone or thin' \
  --libc auto --mode invalid

host_libc="$("${ABI_VERIFIER}" --detect /proc/$$/exe)" ||
  Fail 'could not detect the release-test host libc'
case "${host_libc}" in
  glibc) cross_libc=musl ;;
  musl) cross_libc=glibc ;;
  *) Fail "unsupported release-test host libc: ${host_libc}" ;;
esac
toolchain_probe="$(mktemp)"
trap 'rm -f -- "${toolchain_probe}"' EXIT
ExpectRejected 'standalone mode requires a native' \
  --libc "${cross_libc}" --mode standalone --toolchain "${toolchain_probe}"

if grep -En \
    '(^|[;&|[:space:]])(podman|docker|buildah|nerdctl|xbps-install)([;&|[:space:]]|$)' \
    "${BUILDER}" "${ROOT}/Makefile" >/dev/null; then
  Fail 'release build route invokes an automatic container or Void builder'
fi
for obsolete_path in \
  "${ROOT}/scripts/build_release_matrix.sh" \
  "${ROOT}/scripts/ensure_void_musl_builder.sh" \
  "${ROOT}/packaging/void-musl-builder.Dockerfile"; do
  [[ ! -e "${obsolete_path}" ]] ||
    Fail "obsolete container build path remains: ${obsolete_path}"
done

linked_libc="$("${ABI_VERIFIER}" --detect "${BUILD_DIR}/sighter")" ||
  Fail 'could not detect the test build libc'
case "${linked_libc}" in
  glibc) other_libc=musl ;;
  musl) other_libc=glibc ;;
  *) Fail "unsupported test build libc: ${linked_libc}" ;;
esac
"${ABI_VERIFIER}" --libc "${linked_libc}" "${BUILD_DIR}/sighter"
if "${ABI_VERIFIER}" --libc "${other_libc}" \
    "${BUILD_DIR}/sighter" >/dev/null 2>&1; then
  Fail "${linked_libc} build incorrectly passed the ${other_libc} ABI gate"
fi

printf 'selected libc/mode release contract test passed\n'

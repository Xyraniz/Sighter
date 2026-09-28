#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

readonly ROOT="${1:?source root is required}"
readonly MANIFEST="${ROOT}/packaging/flatpak/space.bigrat.sighter.json"
readonly BUILD_HELPER="${ROOT}/scripts/build_flatpak.sh"
readonly GITHUB_CI="${ROOT}/.github/workflows/flatpak.yml"
readonly TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_DIR}"' EXIT

Fail() {
  printf 'Flatpak packaging test failed: %s\n' "$*" >&2
  exit 1
}

python3 - "${MANIFEST}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)

assert manifest["app-id"] == "space.bigrat.sighter"
assert manifest["runtime"] == "org.gnome.Platform"
assert manifest["runtime-version"] == "50"
assert manifest["sdk"] == "org.gnome.Sdk"
assert manifest["command"] == "sighter"
assert "sdk-extensions" not in manifest

finish_args = set(manifest["finish-args"])
required_permissions = {
    "--share=network",
    "--socket=wayland",
    "--socket=fallback-x11",
    "--socket=pulseaudio",
    "--device=dri",
    "--filesystem=xdg-run/discord-ipc-0:rw",
}
assert required_permissions <= finish_args
assert not any(argument.startswith("--filesystem=host") for argument in finish_args)
assert not any(argument == "--filesystem=home" for argument in finish_args)

modules = {module["name"]: module for module in manifest["modules"]}
for required in (
    "sdl3",
    "sdl3-ttf",
    "nlohmann-json",
    "utf8proc",
    "minizip",
    "capstone",
    "libplacebo",
    "sighter",
):
    assert required in modules
for forbidden in (
    "python-updater-dependencies",
    "ripgrep",
    "binutils-readelf",
    "java-runtime",
    "android-build-tools",
):
    assert forbidden not in modules

sdl_source = modules["sdl3"]["sources"][0]
assert "3.4." in sdl_source["url"]
assert re.fullmatch(r"[0-9a-f]{64}", sdl_source["sha256"])

sdl_options = set(modules["sdl3"]["config-opts"])
assert "-DCMAKE_INSTALL_LIBDIR=lib" in sdl_options

sdl_ttf_options = set(modules["sdl3-ttf"]["config-opts"])
assert "-DCMAKE_INSTALL_LIBDIR=lib" in sdl_ttf_options
assert "-DSDLTTF_VENDORED=OFF" in sdl_ttf_options
assert "-DSDLTTF_SAMPLES=OFF" in sdl_ttf_options

capstone_options = set(modules["capstone"]["config-opts"])
assert modules["capstone"]["builddir"] is True
assert "-DCMAKE_INSTALL_LIBDIR=lib" in capstone_options
assert "-DBUILD_SHARED_LIBS=ON" in capstone_options
assert "-DCAPSTONE_X86_SUPPORT=ON" in capstone_options
assert "-DCAPSTONE_ARCHITECTURE_DEFAULT=OFF" in capstone_options

libplacebo_options = set(modules["libplacebo"]["config-opts"])
assert "--libdir=lib" in libplacebo_options

assert manifest["build-options"]["strip"] is True
assert manifest["build-options"]["no-debuginfo"] is True
assert "env" not in manifest["build-options"]

project_sources = modules["sighter"]["sources"]
assert project_sources == [
    {"type": "git", "path": "../..", "branch": "main"}
]
sighter_options = set(modules["sighter"]["config-opts"])
assert "-DBUILD_TESTING=OFF" in sighter_options
assert "-DSIGHTER_BUILD_FREEBSD_SOCKET_HELPER=OFF" in sighter_options
assert "-DCMAKE_INSTALL_LIBDIR=lib" in sighter_options
assert (
    "-DSIGHTER_DEFAULT_COMPATIBILITY_MANIFEST="
    "/app/share/sighter/metadata/roblox_compatibility.json"
) in sighter_options
assert (
    "-DSIGHTER_DEFAULT_SIGNING_TRUST_MANIFEST="
    "/app/share/sighter/metadata/roblox_signing_certificates.json"
) in sighter_options

for module in manifest["modules"]:
    for source in module.get("sources", []):
        assert source["type"] != "dir", "broad worktree copies can include credentials"
        if "url" in source:
            assert re.fullmatch(r"[0-9a-f]{64}", source.get("sha256", ""))
PY

[[ ! -e "${ROOT}/packaging/flatpak/sighter-flatpak-launcher.sh" ]] ||
  Fail 'Flatpak still uses a shell launcher'
grep -Fq 'sighter_updater' "${ROOT}/CMakeLists.txt" ||
  Fail 'native updater is not installed with Sighter'
grep -Fq 'CleanupStaleBuilderMounts' "${BUILD_HELPER}" ||
  Fail 'build helper does not recover a stale sandboxed builder mount'

[[ -f "${GITHUB_CI}" && ! -L "${GITHUB_CI}" ]] ||
  Fail 'GitHub Actions configuration is missing or unsafe'
[[ ! -e "${ROOT}/.gitlab-ci.yml" ]] ||
  Fail 'obsolete GitLab CI configuration is still present'
grep -Fq 'name: Flatpak' "${GITHUB_CI}" ||
  Fail 'GitHub Actions workflow has no stable display name'
validates_main=false
if grep -Fq 'branches: [main]' "${GITHUB_CI}"; then
  validates_main=true
elif grep -Fq 'workflow_run:' "${GITHUB_CI}" &&
     grep -Fq 'workflows: [Native packages]' "${GITHUB_CI}" &&
     grep -Fq "head_branch == 'main'" "${GITHUB_CI}"; then
  validates_main=true
fi
[[ "${validates_main}" == true ]] ||
  Fail 'GitHub Actions does not validate the main branch'
grep -Fq 'pull_request:' "${GITHUB_CI}" ||
  Fail 'GitHub Actions does not validate pull requests'
grep -Fq 'workflow_dispatch:' "${GITHUB_CI}" ||
  Fail 'GitHub Actions cannot be started manually'
grep -Fq 'contents: read' "${GITHUB_CI}" ||
  Fail 'GitHub Actions default permissions are not read-only'
grep -Fq 'submodules: recursive' "${GITHUB_CI}" ||
  Fail 'GitHub Actions does not initialize pinned source dependencies'
grep -Fq 'runs-on: ubuntu-24.04' "${GITHUB_CI}" ||
  Fail 'GitHub Actions runner is not pinned'
grep -Fq -- '--jobs=4' "${GITHUB_CI}" ||
  Fail 'GitHub Actions does not cap Flatpak build parallelism'
grep -Fq -- '--install-deps-from=flathub' "${GITHUB_CI}" ||
  Fail 'GitHub Actions does not install manifest dependencies from Flathub'
grep -Fq -- '--default-branch=stable' "${GITHUB_CI}" ||
  Fail 'GitHub Actions does not produce the stable Flatpak branch'
grep -Fq 'Sighter-${FLATPAK_ARCH}.flatpak' "${GITHUB_CI}" ||
  Fail 'GitHub Actions does not build the installable Flatpak bundle'
grep -Fq 'ubuntu-24.04-arm' "${GITHUB_CI}" ||
  Fail 'GitHub Actions does not build Flatpak on an ARM64 runner'
grep -Fq 'actions/upload-artifact@' "${GITHUB_CI}" ||
  Fail 'GitHub Actions does not publish the Flatpak artifact'
grep -Fq 'retention-days: 14' "${GITHUB_CI}" ||
  Fail 'GitHub Actions artifact retention is not bounded'
if grep -Fq 'pull_request_target:' "${GITHUB_CI}"; then
  Fail 'GitHub Actions uses the unsafe pull_request_target trigger'
fi

dry_run="$(
  make -C "${ROOT}" --no-print-directory --dry-run flatpak \
    FLATPAK_BUILD_DIR=build-flatpak-test | tr -d '"'
)"
grep -Fq './scripts/build_flatpak.sh' <<<"${dry_run}" ||
  Fail 'make flatpak does not invoke the guarded Flatpak builder'
grep -Fq -- '--manifest packaging/flatpak/space.bigrat.sighter.json' \
  <<<"${dry_run}" || Fail 'make flatpak lost the canonical manifest'
grep -Fq -- '--jobs 4' <<<"${dry_run}" ||
  Fail 'make flatpak does not cap local build parallelism'

mkdir -p -- "${TEMP_DIR}/bin"
cat >"${TEMP_DIR}/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'x86_64\n'
EOF
cat >"${TEMP_DIR}/bin/flatpak" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 0755 "${TEMP_DIR}/bin/uname" "${TEMP_DIR}/bin/flatpak"

set +e
PATH="${TEMP_DIR}/bin:/usr/bin:/bin" \
  "${BUILD_HELPER}" --build-dir "${ROOT}/build-flatpak-test" \
  >"${TEMP_DIR}/stdout" 2>"${TEMP_DIR}/stderr"
helper_status=$?
set -e
[[ "${helper_status}" -ne 0 ]] || Fail 'helper accepted a missing builder'
grep -Fq 'flatpak-builder is unavailable' "${TEMP_DIR}/stderr" ||
  Fail 'helper did not explain how to install flatpak-builder'

cat >"${TEMP_DIR}/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'aarch64\n'
EOF
cat >"${TEMP_DIR}/bin/flatpak-builder" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${SIGHTER_TEST_BUILDER_ARGS}"
EOF
chmod 0755 "${TEMP_DIR}/bin/flatpak-builder"
PATH="${TEMP_DIR}/bin:/usr/bin:/bin" \
  SIGHTER_TEST_BUILDER_ARGS="${TEMP_DIR}/builder-args" \
  "${BUILD_HELPER}" --build-dir "${ROOT}/build-flatpak-test"
grep -Fxq -- '--arch=aarch64' "${TEMP_DIR}/builder-args" ||
  Fail 'local Flatpak helper did not select aarch64'

printf 'Flatpak packaging contract test passed\n'
